import Foundation
import SQLite3
import Testing
import Domain
@testable import Persistence

@Suite struct SQLiteDatabaseTests {

    private func temporaryDatabasePath() -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ua057-db-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("db.sqlite").path
    }

    private func makeVersionOneFixture(at path: String, whisperModelID: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else { throw SQLiteError.openFailed(path) }
        defer { sqlite3_close(handle) }
        let statements = ["PRAGMA journal_mode = WAL", "CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)"]
            + SQLiteMigrations.all[0].statements
            + [
                "INSERT INTO schema_migrations (version, applied_at) VALUES (1, '2026-10-01T00:00:00Z')",
                """
                INSERT INTO qa_entries (id, asked_at, question_status, trigger_kind, answer_text, answer_status, model_id, created_at, updated_at, question_text)
                VALUES ('\(UUID().uuidString)', '2026-10-01T10:00:00Z', 'completed', 'automatic', 'старый ответ', 'completed', '\(whisperModelID)', '2026-10-01T10:00:00Z', '2026-10-01T10:00:00Z', 'старый вопрос')
                """,
            ]
        for statement in statements {
            guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else {
                throw SQLiteError.execFailed(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private func rawStrings(at path: String, _ sql: String) throws -> [String?] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else { throw SQLiteError.openFailed(path) }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var values: [String?] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(sqlite3_column_text(statement, 0).map { String(cString: $0) })
        }
        return values
    }

    @Test func concurrentFirstLaunchMigratesOnce() async throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let shared = SQLiteDatabase(path: path)
        let secondConnection = SQLiteDatabase(path: path)
        let meetings = SQLiteMeetingRepository(database: shared)
        let answers = SQLiteQuestionAnswerRepository(database: shared)
        let summaries = SQLiteSummaryRepository(database: shared)
        let otherMeetings = SQLiteMeetingRepository(database: secondConnection)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await meetings.createMeeting(startedAt: Date(), sourceAppBundleID: nil) }
            group.addTask { _ = try await answers.history(limit: 1) }
            group.addTask { _ = try await summaries.fetch(meetingID: MeetingID()) }
            group.addTask { _ = try await otherMeetings.createMeeting(startedAt: Date(), sourceAppBundleID: nil) }
            try await group.waitForAll()
        }

        #expect(try await shared.appliedMigrationVersions() == [1, 2, 3, 4, 5, 6])
        #expect(try await secondConnection.appliedMigrationVersions() == [1, 2, 3, 4, 5, 6])
        let meetingCount = try await shared.query("SELECT COUNT(*) FROM meetings", map: { $0.int(0) ?? 0 })
        #expect(meetingCount == [2])
    }

    @Test func busyTimeoutAllowsConcurrentWriterOnSecondConnection() async throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let first = SQLiteMeetingRepository(database: SQLiteDatabase(path: path))
        let second = SQLiteMeetingRepository(database: SQLiteDatabase(path: path))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                let repository = index.isMultiple(of: 2) ? first : second
                group.addTask { _ = try await repository.createMeeting(startedAt: Date(), sourceAppBundleID: nil) }
            }
            try await group.waitForAll()
        }

        let check = SQLiteDatabase(path: path)
        try await check.ensureReady()
        #expect(try await check.query("SELECT COUNT(*) FROM meetings", map: { $0.int(0) ?? 0 }) == [40])
    }

    @Test func migrationV2CreatesBackupFileOfVersionOneDatabase() async throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try makeVersionOneFixture(at: path, whisperModelID: "openai_whisper-small")

        let database = SQLiteDatabase(path: path)
        #expect(try await database.appliedMigrationVersions() == [1, 2, 3, 4, 5, 6])

        let backupURL = SQLiteDatabase.backupURL(forDatabaseAt: path, beforeVersion: 2)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(try rawStrings(at: backupURL.path, "SELECT version FROM schema_migrations ORDER BY version") == ["1"])
        #expect(try rawStrings(at: backupURL.path, "SELECT model_id FROM qa_entries") == ["openai_whisper-small"])
    }

    @Test func freshDatabaseSkipsBackup() async throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let database = SQLiteDatabase(path: path)
        try await database.ensureReady()
        #expect(!FileManager.default.fileExists(atPath: SQLiteDatabase.backupURL(forDatabaseAt: path, beforeVersion: 2).path))
    }

    @Test func existingV1DatabaseUpgradesWithoutDataLoss() async throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try makeVersionOneFixture(at: path, whisperModelID: "openai_whisper-small")

        let repository = SQLiteQuestionAnswerRepository(path: path)
        let history = try await repository.history(limit: 10)

        #expect(history.count == 1)
        #expect(history.first?.questionText == "старый вопрос")
        #expect(history.first?.answerText == "старый ответ")
        #expect(history.first?.answerModelID == "gpt-realtime-2.1")
        #expect(history.first?.questionTranscriptionModelID == "openai_whisper-small")
        #expect(try await repository.search(query: "ответ").count == 1)
    }

    @Test func questionTranscriptionModelRoundTrips() async throws {
        let repository = SQLiteQuestionAnswerRepository(path: ":memory:")
        let pair = QuestionAnswerPair(
            askedAt: Date(),
            sourceAppBundleID: nil,
            contextWindowStartedAt: Date(),
            contextWindowDurationMs: 0,
            triggerKind: .manual,
            answerText: "ok",
            answerModelID: "gpt-realtime-2.1",
            questionTranscriptionModelID: "openai_whisper-small",
            responseID: "r1",
            status: .completed
        )
        try await repository.save(pair)
        let stored = try await repository.history(limit: 1).first
        #expect(stored?.answerModelID == "gpt-realtime-2.1")
        #expect(stored?.questionTranscriptionModelID == "openai_whisper-small")
    }
}
