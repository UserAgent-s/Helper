import Domain
import Foundation
import Testing
@testable import Persistence

@Suite struct SessionRetentionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func days(_ value: Double) -> Date {
        now.addingTimeInterval(-value * 86_400)
    }

    private struct Fixture {
        let database: SQLiteDatabase
        let sessions: SQLiteSessionRepository
        let sweeper: RetentionSweeper
        let recordings: URL
    }

    private func makeFixture() -> Fixture {
        let database = SQLiteDatabase(path: ":memory:")
        let recordings = FileManager.default.temporaryDirectory.appendingPathComponent("ua057-ret-\(UUID().uuidString)")
        return Fixture(database: database, sessions: SQLiteSessionRepository(database: database), sweeper: RetentionSweeper(database: database, recordingsDirectory: recordings), recordings: recordings)
    }

    private func finishedSession(_ fixture: Fixture, ageDays: Double, text: String = "старая реплика про кафку") async throws -> SessionID {
        let session = try await fixture.sessions.create(kind: .assistant, mode: .answers, at: days(ageDays))
        try await fixture.sessions.appendUtterance(SessionUtterance(id: "u-\(session.id.rawValue.uuidString)", speaker: .them, origin: .realtimeInput, text: text, capturedAt: days(ageDays)), sessionID: session.id)
        try await fixture.database.run(
            "INSERT INTO screen_contexts (id, session_id, captured_at, application, window_title, text, created_at) VALUES (?, ?, ?, 'Xcode', NULL, 'func secret()', 'x')",
            [.text("s-\(session.id.rawValue.uuidString)"), .text(session.id.rawValue.uuidString), .text(ISO8601DateFormatter().string(from: days(ageDays)))]
        )
        try await fixture.sessions.finish(sessionID: session.id, at: days(ageDays))
        try await fixture.database.run("UPDATE meetings SET last_activity_at = ? WHERE id = ?", [.text(ISO8601DateFormatter().string(from: days(ageDays))), .text(session.id.rawValue.uuidString)])
        return session.id
    }

    private func count(_ fixture: Fixture, _ sql: String) async throws -> Int {
        try await fixture.database.query(sql, map: { $0.int(0) ?? -1 }).first ?? -1
    }

    @Test func purgeDeletesOldUnpinned() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.recordings) }
        let old = try await finishedSession(fixture, ageDays: 40)
        let fresh = try await finishedSession(fixture, ageDays: 5)
        let audio = fixture.recordings.appendingPathComponent(old.rawValue.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data([1]).write(to: audio.appendingPathComponent("me.wav"))

        let report = try await fixture.sweeper.sweep(policy: RetentionPolicy(days: 30), excluding: nil, now: now)

        #expect(report.deletedMeetingIDs == [old])
        #expect(try await fixture.sessions.session(id: old) == nil)
        #expect(try await fixture.sessions.session(id: fresh) != nil)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(try await count(fixture, "SELECT COUNT(*) FROM utterances") == 1)
        #expect(try await count(fixture, "SELECT COUNT(*) FROM screen_contexts") == 1)
    }

    @Test func purgeKeepsPinnedAndActive() async throws {
        let fixture = makeFixture()
        let pinned = try await finishedSession(fixture, ageDays: 400)
        try await fixture.sessions.setPinned(sessionID: pinned, pinned: true)
        let active = try await fixture.sessions.create(kind: .assistant, mode: .answers, at: days(100))
        try await fixture.sessions.addBookmark(SessionBookmark(sessionID: active.id, kind: .moment, markedAt: days(100)))
        let resumedOld = try await finishedSession(fixture, ageDays: 200)
        let unpinnedOld = try await finishedSession(fixture, ageDays: 200)
        try await fixture.database.run("INSERT INTO qa_entries (id, asked_at, question_status, trigger_kind, answer_text, answer_status, model_id, created_at, updated_at, question_text, session_id) VALUES ('qa-pinned', ?, 'completed', 'manual', 'a', 'completed', 'm', 'x', 'x', 'q', ?)", [.text(ISO8601DateFormatter().string(from: days(400))), .text(pinned.rawValue.uuidString)])

        let report = try await fixture.sweeper.sweep(policy: RetentionPolicy(days: 30), excluding: resumedOld, now: now)

        #expect(report.deletedMeetingIDs == [unpinnedOld])
        #expect(try await fixture.sessions.session(id: pinned) != nil)
        #expect(try await fixture.sessions.session(id: active.id) != nil)
        #expect(try await fixture.sessions.session(id: resumedOld) != nil)
        #expect(try await count(fixture, "SELECT COUNT(*) FROM qa_entries WHERE id = 'qa-pinned'") == 1)
    }

    @Test func purgeRemovesFtsRows() async throws {
        let fixture = makeFixture()
        let old = try await finishedSession(fixture, ageDays: 40, text: "уникальнаяфраза шардирование")
        try await fixture.database.run("INSERT INTO qa_entries (id, asked_at, question_status, trigger_kind, answer_text, answer_status, model_id, created_at, updated_at, question_text, session_id) VALUES ('qa-old', ?, 'completed', 'manual', 'ответ про шардирование', 'completed', 'm', 'x', 'x', 'вопрос', ?)", [.text(ISO8601DateFormatter().string(from: days(40))), .text(old.rawValue.uuidString)])
        let search = SQLiteSessionSearchRepository(database: fixture.database)
        #expect(try await search.search(query: "шардирование", limit: 10).count == 1)

        _ = try await fixture.sweeper.sweep(policy: RetentionPolicy(days: 30), excluding: nil, now: now)

        #expect(try await search.search(query: "шардирование", limit: 10).isEmpty)
        #expect(try await search.search(query: "secret", limit: 10).isEmpty)
        for index in ["utterances_fts", "utterances_trgm", "qa_entries_fts", "qa_entries_trgm", "screen_contexts_fts", "screen_contexts_trgm"] {
            #expect(try await count(fixture, "SELECT COUNT(*) FROM \(index)_docsize") == 0, "\(index)")
        }
        #expect(try await count(fixture, "PRAGMA secure_delete") == 1)
    }

    @Test func retentionNilIsNoop() async throws {
        let fixture = makeFixture()
        let ancient = try await finishedSession(fixture, ageDays: 5000)
        try await fixture.database.run("INSERT INTO qa_entries (id, asked_at, question_status, trigger_kind, answer_text, answer_status, model_id, created_at, updated_at, question_text) VALUES ('legacy', ?, 'completed', 'manual', 'a', 'completed', 'm', 'x', 'x', 'q')", [.text(ISO8601DateFormatter().string(from: days(5000)))])

        #expect(try await fixture.sweeper.sweep(policy: RetentionPolicy(days: nil), excluding: nil, now: now) == RetentionSweepReport())
        #expect(try await fixture.sweeper.sweep(policy: RetentionPolicy(days: 0), excluding: nil, now: now) == RetentionSweepReport())
        #expect(try await fixture.sessions.session(id: ancient) != nil)
        #expect(try await count(fixture, "SELECT COUNT(*) FROM qa_entries") == 1)
        #expect(try await count(fixture, "SELECT COUNT(*) FROM screen_contexts") == 1)
    }

    @Test func screenTextsOptOutDropsAllButActive() async throws {
        let fixture = makeFixture()
        let finished = try await finishedSession(fixture, ageDays: 1)
        let active = try await finishedSession(fixture, ageDays: 0)
        try await fixture.database.run("INSERT INTO qa_entries (id, asked_at, question_status, trigger_kind, answer_text, answer_status, model_id, created_at, updated_at, question_text, session_id, screen_context_id) VALUES ('qa-s', 'x', 'completed', 'manual', 'a', 'completed', 'm', 'x', 'x', 'q', ?, ?)", [.text(finished.rawValue.uuidString), .text("s-\(finished.rawValue.uuidString)")])

        let report = try await fixture.sweeper.sweep(policy: RetentionPolicy(days: nil, keepScreenTexts: false), excluding: active, now: now)

        #expect(report.deletedScreenContextCount == 1)
        #expect(report.deletedMeetingIDs.isEmpty)
        #expect(try await count(fixture, "SELECT COUNT(*) FROM screen_contexts WHERE session_id = '\(active.rawValue.uuidString)'") == 1)
        #expect(try await count(fixture, "SELECT COUNT(*) FROM qa_entries WHERE id = 'qa-s' AND screen_context_id IS NULL") == 1)
        #expect(try await fixture.sessions.session(id: finished) != nil)
    }
}
