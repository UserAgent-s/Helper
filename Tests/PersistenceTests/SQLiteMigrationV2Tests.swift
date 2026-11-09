import Domain
import Foundation
import Testing
@testable import Persistence

@Suite struct SQLiteMigrationV2Tests {
    private let meetingID = "11111111-1111-1111-1111-111111111111"

    private func temporaryDatabasePath() -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ua057-v4-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("db.sqlite").path
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    private var legacyMigrations: [SQLiteMigration] {
        SQLiteMigrations.all.filter { $0.version <= 3 }
    }

    private func makePopulatedLegacyDatabase(at path: String) async throws {
        let legacy = SQLiteDatabase(path: path, migrations: legacyMigrations)
        try await legacy.ensureReady()
        try await legacy.run(
            "INSERT INTO meetings (id, title, source_bundle_id, started_at, ended_at, status, created_at, updated_at) VALUES (?, 'Старый созвон', NULL, '2026-10-01T10:00:00Z', '2026-10-01T10:30:00Z', 'completed', '2026-10-01T10:00:00Z', '2026-10-01T10:30:00Z')",
            [.text(meetingID)]
        )
        try await legacy.run(
            "INSERT INTO utterances (id, meeting_id, source, started_ms, ended_ms, text, created_at) VALUES ('u1', ?, 'remote', 65000, 67000, 'Расскажите про Kafka и ёлку', '2026-10-01T10:01:05Z')",
            [.text(meetingID)]
        )
        try await legacy.run(
            "INSERT INTO utterances (id, meeting_id, source, started_ms, ended_ms, text, created_at) VALUES ('u2', ?, 'local', 70000, 72000, 'Я писал консьюмеры', '2026-10-01T10:01:10Z')",
            [.text(meetingID)]
        )
        try await legacy.run(
            "INSERT INTO qa_entries (id, asked_at, question_status, trigger_kind, answer_text, answer_status, model_id, created_at, updated_at, question_text) VALUES ('q1', '2026-10-01T10:02:00Z', 'completed', 'automatic', 'старый ответ', 'completed', 'gpt-realtime-2.1', '2026-10-01T10:02:00Z', '2026-10-01T10:02:00Z', 'старый вопрос')"
        )
    }

    private func strings(_ database: SQLiteDatabase, _ sql: String, _ params: [SQLiteValue] = []) async throws -> [String?] {
        try await database.query(sql, params, map: { $0.string(0) })
    }

    private func count(_ database: SQLiteDatabase, _ sql: String, _ params: [SQLiteValue] = []) async throws -> Int {
        try await database.query(sql, params, map: { $0.int(0) ?? 0 }).first ?? 0
    }

    private func columns(_ database: SQLiteDatabase, _ table: String) async throws -> Set<String> {
        Set(try await strings(database, "SELECT name FROM pragma_table_info('\(table)')").compactMap { $0 })
    }

    private func seedSession(_ database: SQLiteDatabase, id: String) async throws {
        try await database.ensureReady()
        try await database.run(
            "INSERT INTO meetings (id, started_at, status, created_at, updated_at, kind) VALUES (?, '2026-11-01T09:00:00Z', 'recording', '2026-11-01T09:00:00Z', '2026-11-01T09:00:00Z', 'assistant')",
            [.text(id)]
        )
        try await database.run("INSERT INTO session_spans (id, session_id, mode, started_at) VALUES ('s_\(id)', ?, 'answers', '2026-11-01T09:00:00Z')", [.text(id)])
        try await database.run(
            "INSERT INTO utterances (id, meeting_id, source, started_ms, ended_ms, text, created_at, speaker, origin, captured_at, translation_text, translation_lang) VALUES ('u_\(id)', ?, 'remote', 0, 1000, 'Как устроен шардинг?', '2026-11-01T09:00:01Z', 'them', 'realtime_input', '2026-11-01T09:00:01Z', 'How does sharding work?', 'en')",
            [.text(id)]
        )
        try await database.run("INSERT INTO screen_contexts (id, session_id, captured_at, application, text, created_at) VALUES ('sc_\(id)', ?, '2026-11-01T09:00:02Z', 'Xcode', 'func shardKey(for order: Order)', '2026-11-01T09:00:02Z')", [.text(id)])
        try await database.run(
            "INSERT INTO qa_entries (id, asked_at, question_status, trigger_kind, answer_text, answer_status, model_id, created_at, updated_at, question_text, session_id, screen_context_id) VALUES ('q_\(id)', '2026-11-01T09:00:03Z', 'completed', 'manual', 'Шардинг по ключу заказа', 'completed', 'gpt-realtime-2.1', '2026-11-01T09:00:03Z', '2026-11-01T09:00:03Z', 'Как устроен шардинг?', ?, 'sc_\(id)')",
            [.text(id)]
        )
        try await database.run("INSERT INTO deep_expansions (id, session_id, qa_entry_id, requested_at, model_id, status, text, created_at, updated_at) VALUES ('d_\(id)', ?, 'q_\(id)', '2026-11-01T09:00:04Z', 'claude-sonnet-5-5', 'completed', 'Консистентное хеширование уменьшает перебалансировку', '2026-11-01T09:00:04Z', '2026-11-01T09:00:04Z')", [.text(id)])
        try await database.run("INSERT INTO bookmarks (id, session_id, kind, qa_entry_id, marked_at, note, created_at) VALUES ('b_\(id)', ?, 'star', 'q_\(id)', '2026-11-01T09:00:05Z', 'вернуться к хешированию', '2026-11-01T09:00:05Z')", [.text(id)])
    }

    @Test func migratesPopulatedV1Database() async throws {
        let path = temporaryDatabasePath()
        defer { cleanup(path) }
        try await makePopulatedLegacyDatabase(at: path)

        let database = SQLiteDatabase(path: path)
        #expect(try await database.appliedMigrationVersions() == [1, 2, 3, 4])
        #expect(try await strings(database, "SELECT kind || '|' || pinned || '|' || last_activity_at || '|' || title_source FROM meetings") == ["recording|0|2026-10-01T10:30:00Z|legacy"])
        #expect(try await strings(database, "SELECT speaker || '|' || origin || '|' || captured_at FROM utterances ORDER BY started_ms") == [
            "them|whisper_local|2026-10-01T10:01:05Z",
            "me|whisper_local|2026-10-01T10:01:10Z",
        ])
        #expect(try await strings(database, "SELECT mode || '|' || started_at || '|' || ended_at FROM session_spans WHERE session_id = ?", [.text(meetingID)]) == ["recording|2026-10-01T10:00:00Z|2026-10-01T10:30:00Z"])
        #expect(try await strings(database, "SELECT session_id FROM qa_entries") == [nil])

        let backup = SQLiteDatabase.backupURL(forDatabaseAt: path, beforeVersion: 4)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let snapshot = SQLiteDatabase(path: backup.path, migrations: [])
        try await snapshot.ensureReady()
        #expect(try await strings(snapshot, "SELECT MAX(version) FROM schema_migrations") == ["3"])
        #expect(try await count(snapshot, "SELECT COUNT(*) FROM utterances") == 2)

        let meeting = try await SQLiteMeetingRepository(database: database).fetch(meetingID: MeetingID(rawValue: UUID(uuidString: meetingID)!))
        #expect(meeting.title == "Старый созвон")
        #expect(meeting.segments.map(\.source) == [.remote, .local])
    }

    @Test func ftsRebuiltFindsLegacyUtterance() async throws {
        let path = temporaryDatabasePath()
        defer { cleanup(path) }
        try await makePopulatedLegacyDatabase(at: path)
        let database = SQLiteDatabase(path: path)
        try await database.ensureReady()

        #expect(try await count(database, "SELECT COUNT(*) FROM utterances_fts WHERE utterances_fts MATCH 'елку'") == 1)
        #expect(try await count(database, "SELECT COUNT(*) FROM utterances_fts WHERE utterances_fts MATCH 'KAF*'") == 1)
        #expect(try await count(database, "SELECT COUNT(*) FROM utterances_trgm WHERE utterances_trgm MATCH 'онсьюм'") == 1)
        #expect(try await count(database, "SELECT COUNT(*) FROM qa_entries_fts WHERE qa_entries_fts MATCH 'ответ'") == 1)
        #expect(try await count(database, "SELECT COUNT(*) FROM qa_entries_trgm WHERE qa_entries_trgm MATCH 'тарый'") == 1)
        let found = try await SQLiteMeetingRepository(database: database).search(query: "Kafka")
        #expect(found.map(\.id.rawValue.uuidString) == [meetingID])
        #expect(try await SQLiteQuestionAnswerRepository(database: database).search(query: "вопрос").count == 1)
        #expect(try await count(database, "SELECT COUNT(*) FROM search_aliases WHERE term = 'KAFKA'") == 1)
    }

    @Test func deleteSessionCascadesAllChildren() async throws {
        let database = SQLiteDatabase(path: ":memory:")
        try await seedSession(database, id: "keep")
        try await seedSession(database, id: "gone")

        try await database.run("DELETE FROM meetings WHERE id = 'gone'")

        for table in ["session_spans", "utterances", "screen_contexts", "deep_expansions", "bookmarks"] {
            let column = table == "utterances" ? "meeting_id" : "session_id"
            #expect(try await count(database, "SELECT COUNT(*) FROM \(table) WHERE \(column) = 'gone'") == 0, "\(table)")
            #expect(try await count(database, "SELECT COUNT(*) FROM \(table) WHERE \(column) = 'keep'") == 1, "\(table)")
        }
        #expect(try await strings(database, "SELECT id FROM qa_entries") == ["q_keep"])
        #expect(try await count(database, "SELECT COUNT(*) FROM utterances_fts WHERE utterances_fts MATCH 'шардинг'") == 1)
        #expect(try await count(database, "SELECT COUNT(*) FROM utterances_trgm WHERE utterances_trgm MATCH 'sharding'") == 1)
        #expect(try await count(database, "SELECT COUNT(*) FROM qa_entries_fts WHERE qa_entries_fts MATCH 'шардинг'") == 1)
        #expect(try await count(database, "SELECT COUNT(*) FROM screen_contexts_trgm WHERE screen_contexts_trgm MATCH 'shardKey'") == 1)
        #expect(try await count(database, "SELECT COUNT(*) FROM deep_expansions_fts WHERE deep_expansions_fts MATCH 'хеширование'") == 1)
        #expect(try await count(database, "SELECT COUNT(*) FROM bookmarks_fts WHERE bookmarks_fts MATCH 'хешированию'") == 1)
    }

    @Test func ftsTriggersOnNewTables() async throws {
        let database = SQLiteDatabase(path: ":memory:")
        try await seedSession(database, id: "s")

        #expect(try await count(database, "SELECT COUNT(*) FROM utterances_fts WHERE utterances_fts MATCH 'translation_text:sharding'") == 1)
        #expect(try await count(database, "SELECT COUNT(*) FROM screen_contexts_fts WHERE screen_contexts_fts MATCH 'application:xcode'") == 1)
        #expect(try await count(database, "SELECT COUNT(*) FROM deep_expansions_trgm WHERE deep_expansions_trgm MATCH 'балансир'") == 1)

        try await database.run("UPDATE deep_expansions SET text = 'Виртуальные узлы' WHERE id = 'd_s'")
        #expect(try await count(database, "SELECT COUNT(*) FROM deep_expansions_fts WHERE deep_expansions_fts MATCH 'хеширование'") == 0)
        #expect(try await count(database, "SELECT COUNT(*) FROM deep_expansions_fts WHERE deep_expansions_fts MATCH 'узлы'") == 1)
        #expect(try await count(database, "SELECT COUNT(*) FROM deep_expansions_trgm WHERE deep_expansions_trgm MATCH 'балансир'") == 0)

        try await database.run("UPDATE bookmarks SET note = 'Ёмкость кластера' WHERE id = 'b_s'")
        #expect(try await count(database, "SELECT COUNT(*) FROM bookmarks_fts WHERE bookmarks_fts MATCH 'емкость'") == 1)

        try await database.run("DELETE FROM screen_contexts WHERE id = 'sc_s'")
        #expect(try await strings(database, "SELECT screen_context_id FROM qa_entries WHERE id = 'q_s'") == [nil])
        #expect(try await count(database, "SELECT COUNT(*) FROM screen_contexts_trgm WHERE screen_contexts_trgm MATCH 'shardKey'") == 0)
    }

    @Test func migrationIsIdempotentOnReopen() async throws {
        let path = temporaryDatabasePath()
        defer { cleanup(path) }
        try await makePopulatedLegacyDatabase(at: path)
        let first = SQLiteDatabase(path: path)
        try await first.ensureReady()
        let backup = SQLiteDatabase.backupURL(forDatabaseAt: path, beforeVersion: 4)
        let backupDate = try FileManager.default.attributesOfItem(atPath: backup.path)[.modificationDate] as? Date

        let reopened = SQLiteDatabase(path: path)
        #expect(try await reopened.appliedMigrationVersions() == [1, 2, 3, 4])
        #expect(try await count(reopened, "SELECT COUNT(*) FROM session_spans") == 1)
        #expect(try await count(reopened, "SELECT COUNT(*) FROM search_aliases") == 10)
        #expect(try await count(reopened, "SELECT COUNT(*) FROM utterances_fts WHERE utterances_fts MATCH 'kafka'") == 1)
        #expect(try FileManager.default.attributesOfItem(atPath: backup.path)[.modificationDate] as? Date == backupDate)
    }

    @Test func failedMigrationRollsBack() async throws {
        let path = temporaryDatabasePath()
        defer { cleanup(path) }
        try await makePopulatedLegacyDatabase(at: path)
        let broken = legacyMigrations + [SQLiteMigration(version: 4, statements: SessionSchema.statements + ["INSERT INTO no_such_table VALUES (1)"], backsUpExistingDatabase: true)]

        let failing = SQLiteDatabase(path: path, migrations: broken)
        await #expect(throws: SQLiteError.self) { try await failing.ensureReady() }

        let inspect = SQLiteDatabase(path: path, migrations: legacyMigrations)
        #expect(try await inspect.appliedMigrationVersions() == [1, 2, 3])
        #expect(!(try await columns(inspect, "meetings")).contains("kind"))
        #expect(!(try await columns(inspect, "utterances")).contains("speaker"))
        #expect(try await count(inspect, "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('session_spans', 'bookmarks', 'utterances_trgm')") == 0)
        #expect(try await count(inspect, "SELECT COUNT(*) FROM utterances_fts WHERE utterances_fts MATCH 'Kafka'") == 1)
        #expect(FileManager.default.fileExists(atPath: SQLiteDatabase.backupURL(forDatabaseAt: path, beforeVersion: 4).path))

        let recovered = SQLiteDatabase(path: path)
        #expect(try await recovered.appliedMigrationVersions() == [1, 2, 3, 4])
        #expect(try await count(recovered, "SELECT COUNT(*) FROM utterances") == 2)
    }
}
