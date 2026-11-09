import Foundation
import SQLite3

public actor SQLiteDatabase {
    public let path: String
    private let busyTimeoutMs: Int
    private let owner = SQLiteHandleOwner()
    private var handle: OpaquePointer? {
        get { owner.handle }
        set { owner.handle = newValue }
    }
    private var didMigrate = false
    private let migrations: [SQLiteMigration]

    public init(path: String, busyTimeoutMs: Int = 5000) {
        self.init(path: path, busyTimeoutMs: busyTimeoutMs, migrations: SQLiteMigrations.all)
    }

    init(path: String, busyTimeoutMs: Int = 5000, migrations: [SQLiteMigration]) {
        self.path = path
        self.busyTimeoutMs = busyTimeoutMs
        self.migrations = migrations
    }

    public func ensureReady() throws {
        if handle == nil {
            try open()
        }
        if !didMigrate {
            try runMigrations()
            didMigrate = true
        }
    }

    public func appliedMigrationVersions() throws -> [Int] {
        try ensureReady()
        return try query("SELECT version FROM schema_migrations ORDER BY version", map: { row in row.int(0) ?? 0 })
    }

    public func backup(to url: URL) throws {
        try ensureReady()
        try copyDatabase(to: url)
    }

    public nonisolated static func backupURL(forDatabaseAt path: String, beforeVersion version: Int) -> URL {
        URL(fileURLWithPath: path + ".pre-v\(version).bak")
    }

    @discardableResult
    func run(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.stepFailed(lastErrorMessage())
        }
        return Int(sqlite3_changes(handle))
    }

    func query<T>(_ sql: String, _ params: [SQLiteValue] = [], map: (SQLiteRow) -> T) throws -> [T] {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        let row = SQLiteRow(statement: statement)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                results.append(map(row))
            } else if result == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.stepFailed(lastErrorMessage())
            }
        }
        return results
    }

    func withTransaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try run("COMMIT")
        } catch {
            _ = try? run("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ params: [SQLiteValue]) throws -> OpaquePointer {
        guard let handle else { throw SQLiteError.prepareFailed("connection not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(lastErrorMessage())
        }
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let bindResult: Int32
            switch value {
            case .text(let text):
                bindResult = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case .int(let intValue):
                bindResult = sqlite3_bind_int64(statement, index, Int64(intValue))
            case .double(let doubleValue):
                bindResult = sqlite3_bind_double(statement, index, doubleValue)
            case .null:
                bindResult = sqlite3_bind_null(statement, index)
            }
            guard bindResult == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw SQLiteError.bindFailed(lastErrorMessage())
            }
        }
        return statement
    }

    private func open() throws {
        var newHandle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &newHandle, flags, nil) == SQLITE_OK, let newHandle else {
            let message = newHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown open error"
            if let newHandle { sqlite3_close_v2(newHandle) }
            throw SQLiteError.openFailed(message)
        }
        sqlite3_busy_timeout(newHandle, Int32(busyTimeoutMs))
        handle = newHandle
        do {
            try enableWriteAheadLog(on: newHandle)
            try run("PRAGMA foreign_keys = ON")
            try run("PRAGMA secure_delete = ON")
        } catch {
            sqlite3_close_v2(newHandle)
            handle = nil
            throw error
        }
    }

    private func enableWriteAheadLog(on handle: OpaquePointer) throws {
        let deadline = Date().addingTimeInterval(Double(busyTimeoutMs) / 1000)
        while true {
            let result = sqlite3_exec(handle, "PRAGMA journal_mode = WAL", nil, nil, nil)
            if result == SQLITE_OK { return }
            guard result == SQLITE_BUSY || result == SQLITE_LOCKED, Date() < deadline else {
                throw SQLiteError.execFailed(String(cString: sqlite3_errmsg(handle)))
            }
            usleep(10_000)
        }
    }

    private func runMigrations() throws {
        var appliedThisLaunch: Set<Int> = []
        if path != ":memory:" {
            _ = try? query("PRAGMA wal_checkpoint(PASSIVE)", map: { _ in 0 })
        }
        for migration in migrations {
            try withTransaction {
                try run("""
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version INTEGER PRIMARY KEY,
                    applied_at TEXT NOT NULL
                )
                """)
                let applied = Set(try query("SELECT version FROM schema_migrations", map: { row in row.int(0) ?? 0 }))
                guard !applied.contains(migration.version) else { return }
                if migration.backsUpExistingDatabase, !applied.subtracting(appliedThisLaunch).isEmpty, path != ":memory:" {
                    try copyDatabase(to: Self.backupURL(forDatabaseAt: path, beforeVersion: migration.version))
                }
                for statement in migration.statements {
                    try run(statement)
                }
                try run(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                    [.int(migration.version), .text(ISO8601DateFormatter().string(from: Date()))]
                )
                appliedThisLaunch.insert(migration.version)
            }
        }
    }

    private func copyDatabase(to url: URL) throws {
        var source: OpaquePointer?
        guard sqlite3_open_v2(path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let source else {
            if let source { sqlite3_close_v2(source) }
            throw SQLiteError.backupFailed("cannot open backup source")
        }
        defer { sqlite3_close_v2(source) }
        sqlite3_busy_timeout(source, Int32(busyTimeoutMs))
        try? FileManager.default.removeItem(at: url)
        var destination: OpaquePointer?
        guard sqlite3_open_v2(url.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let destination
        else {
            if let destination { sqlite3_close_v2(destination) }
            throw SQLiteError.backupFailed("cannot open backup destination")
        }
        defer { sqlite3_close_v2(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw SQLiteError.backupFailed(String(cString: sqlite3_errmsg(destination)))
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw SQLiteError.backupFailed("backup step \(stepResult) finish \(finishResult)")
        }
        guard sqlite3_exec(destination, "PRAGMA journal_mode = DELETE", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.backupFailed(String(cString: sqlite3_errmsg(destination)))
        }
    }

    private func lastErrorMessage() -> String {
        guard let handle else { return "no connection" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

private final class SQLiteHandleOwner: @unchecked Sendable {
    var handle: OpaquePointer?

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }
}
