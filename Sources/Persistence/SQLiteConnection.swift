import Domain
import Foundation
import SQLite3

enum SQLiteError: Error, Sendable, Equatable {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
}

enum SQLiteValue: Sendable {
    case text(String)
    case int(Int)
    case double(Double)
    case null
}

final class SQLiteRow: @unchecked Sendable {
    fileprivate let statement: OpaquePointer

    fileprivate init(statement: OpaquePointer) {
        self.statement = statement
    }

    func string(_ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    func int(_ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    func double(_ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }
}

actor SQLiteConnection {
    private let path: String
    private var handle: OpaquePointer?
    private var didMigrate = false

    init(path: String) {
        self.path = path
    }

    func ensureReady() throws {
        if handle == nil {
            try open()
        }
        if !didMigrate {
            try runMigrations()
            didMigrate = true
        }
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
        guard sqlite3_open(path, &newHandle) == SQLITE_OK else {
            let message = newHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown open error"
            throw SQLiteError.openFailed(message)
        }
        handle = newHandle
        try run("PRAGMA journal_mode = WAL")
        try run("PRAGMA foreign_keys = ON")
    }

    private func runMigrations() throws {
        try run("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
        )
        """)
        let appliedVersions = Set(try query("SELECT version FROM schema_migrations", map: { row in row.int(0) ?? 0 }))
        for migration in SQLiteMigrations.all where !appliedVersions.contains(migration.version) {
            try withTransaction {
                for statement in migration.statements {
                    try run(statement)
                }
                try run(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                    [.int(migration.version), .text(ISO8601DateFormatter().string(from: Date()))]
                )
            }
        }
    }

    private func lastErrorMessage() -> String {
        guard let handle else { return "no connection" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
