import Domain
import Foundation
import Testing
@testable import Persistence

private actor CallLog {
    private(set) var headerCalls = 0
    private(set) var detailCalls = 0

    func header() { headerCalls += 1 }
    func detail() { detailCalls += 1 }
}

private struct SpySessionRepository: SessionRepository {
    let base: SQLiteSessionRepository
    let log: CallLog

    func create(kind: SessionKind, mode: SessionSpanMode, at date: Date) async throws -> AssistantSession { try await base.create(kind: kind, mode: mode, at: date) }
    func resume(sessionID: SessionID, mode: SessionSpanMode, at date: Date) async throws -> SessionSpan { try await base.resume(sessionID: sessionID, mode: mode, at: date) }
    func closeSpan(id: String, at date: Date, reason: SessionSpanEndReason) async throws { try await base.closeSpan(id: id, at: date, reason: reason) }
    func finish(sessionID: SessionID, at date: Date) async throws { try await base.finish(sessionID: sessionID, at: date) }
    func session(id: SessionID) async throws -> AssistantSession? { try await base.session(id: id) }
    func headers(limit: Int, after cursor: SessionCursor?) async throws -> SessionPage {
        await log.header()
        return try await base.headers(limit: limit, after: cursor)
    }
    func detail(sessionID: SessionID) async throws -> SessionDetail? {
        await log.detail()
        return try await base.detail(sessionID: sessionID)
    }
    func addBookmark(_ bookmark: SessionBookmark) async throws { try await base.addBookmark(bookmark) }
    func bookmarks(sessionID: SessionID) async throws -> [SessionBookmark] { try await base.bookmarks(sessionID: sessionID) }
    func latestCompletedAnswerID(sessionID: SessionID) async throws -> UUID? { try await base.latestCompletedAnswerID(sessionID: sessionID) }
    func removeBookmark(id: String) async throws { try await base.removeBookmark(id: id) }
    func setTitle(sessionID: SessionID, title: String, source: SessionTitleSource) async throws { try await base.setTitle(sessionID: sessionID, title: title, source: source) }
    func setPinned(sessionID: SessionID, pinned: Bool) async throws { try await base.setPinned(sessionID: sessionID, pinned: pinned) }
    func purge(olderThan date: Date, excluding active: SessionID?) async throws -> [SessionID] { try await base.purge(olderThan: date, excluding: active) }
    func appendUtterance(_ utterance: SessionUtterance, sessionID: SessionID) async throws { try await base.appendUtterance(utterance, sessionID: sessionID) }
    func deleteIfEmpty(sessionID: SessionID) async throws -> Bool { try await base.deleteIfEmpty(sessionID: sessionID) }
}

@Suite struct SessionHistoryServiceTests {
    private let base = Date(timeIntervalSince1970: 1_793_000_000)

    private func stamp(_ seconds: Int) -> String {
        ISO8601DateFormatter().string(from: base.addingTimeInterval(TimeInterval(seconds)))
    }

    private func answer(_ database: SQLiteDatabase, _ session: SessionID, id: UUID, question: String, at seconds: Int) async throws {
        try await database.run(
            "INSERT INTO qa_entries (id, asked_at, question_status, trigger_kind, answer_text, answer_status, model_id, created_at, updated_at, question_text, session_id) VALUES (?, ?, 'completed', 'manual', 'ответ', 'completed', 'gpt-realtime-2.1', ?, ?, ?, ?)",
            [.text(id.uuidString), .text(stamp(seconds)), .text(stamp(seconds)), .text(stamp(seconds)), .text(question), .text(session.rawValue.uuidString)]
        )
    }

    private func expansion(_ database: SQLiteDatabase, _ session: SessionID, id: String, owner: UUID?, text: String, at seconds: Int) async throws {
        try await database.run(
            "INSERT INTO deep_expansions (id, session_id, qa_entry_id, requested_at, model_id, status, text, created_at, updated_at) VALUES (?, ?, ?, ?, 'claude-sonnet-5-5', 'completed', ?, 'x', 'x')",
            [.text(id), .text(session.rawValue.uuidString), owner.map { .text($0.uuidString) } ?? .null, .text(stamp(seconds)), .text(text)]
        )
    }

    @Test func listLoadsHeadersOnly() async throws {
        let database = SQLiteDatabase(path: ":memory:")
        let sqlite = SQLiteSessionRepository(database: database)
        let log = CallLog()
        let service = SessionHistoryService(repository: SpySessionRepository(base: sqlite, log: log), searcher: SQLiteSessionSearchRepository(database: database), summaries: nil)
        for index in 0..<200 {
            let session = try await sqlite.create(kind: .assistant, mode: .answers, at: base.addingTimeInterval(TimeInterval(index * 60)))
            try await sqlite.appendUtterance(SessionUtterance(id: "u\(index)", speaker: .them, origin: .realtimeInput, text: String(repeating: "реплика ", count: 50), capturedAt: base.addingTimeInterval(TimeInterval(index * 60 + 1))), sessionID: session.id)
        }

        let first = try await service.list(limit: SessionHistoryService.maxPageSize, after: nil)
        let token = try #require(first.nextCursor?.token)
        let second = try await service.list(limit: SessionHistoryService.maxPageSize, after: SessionCursor(token: token))
        let ids = (first.headers + second.headers).map(\.id)
        #expect(ids.count == 200)
        #expect(Set(ids).count == 200)
        #expect(second.nextCursor == nil)
        #expect(first.headers.first?.startedAt == base.addingTimeInterval(TimeInterval(199 * 60)))
        #expect(try await service.list(limit: 10_000, after: nil).headers.count == SessionHistoryService.maxPageSize)
        #expect(await log.headerCalls == 3)
        #expect(await log.detailCalls == 0)
    }

    @Test func detailGroupsExpansionsUnderQA() async throws {
        let database = SQLiteDatabase(path: ":memory:")
        let sqlite = SQLiteSessionRepository(database: database)
        let summaries = SQLiteSummaryRepository(database: database)
        let service = SessionHistoryService(repository: sqlite, searcher: nil, summaries: summaries)
        let session = try await sqlite.create(kind: .assistant, mode: .answers, at: base)
        let first = UUID()
        let second = UUID()
        try await answer(database, session.id, id: second, question: "Второй вопрос", at: 20)
        try await answer(database, session.id, id: first, question: "Первый вопрос", at: 10)
        try await expansion(database, session.id, id: "d2", owner: first, text: "позже", at: 40)
        try await expansion(database, session.id, id: "d1", owner: first, text: "раньше", at: 30)
        try await expansion(database, session.id, id: "d3", owner: second, text: "ко второму", at: 50)
        try await expansion(database, session.id, id: "d4", owner: nil, text: "без вопроса", at: 60)
        try await sqlite.addBookmark(SessionBookmark(sessionID: session.id, kind: .star, questionAnswerID: second, markedAt: base.addingTimeInterval(55)))
        try await summaries.save(MeetingSummary(meetingID: session.id, modelID: "gpt-5", schemaVersion: 1, contentJSON: "{}", renderedMarkdown: "## Итоги", generatedAt: base.addingTimeInterval(70)))

        let detail = try #require(try await service.detail(sessionID: session.id))
        #expect(detail.questions.map(\.pair.id) == [first, second])
        #expect(detail.questions[0].expansions.map(\.id) == ["d1", "d2"])
        #expect(detail.questions[1].expansions.map(\.id) == ["d3"])
        #expect(detail.questions.map(\.starred) == [false, true])
        #expect(detail.unattachedExpansions.map(\.id) == ["d4"])
        #expect(detail.summary?.renderedMarkdown == "## Итоги")
        #expect(try await service.detail(sessionID: SessionID()) == nil)
    }

    @Test func cursorTokenRoundTripsAndRejectsGarbage() {
        let cursor = SessionCursor(startedAt: base, id: SessionID())
        #expect(SessionCursor(token: cursor.token) == cursor)
        #expect(SessionCursor(token: "abc") == nil)
        #expect(SessionCursor(token: "123_not-a-uuid") == nil)
        #expect(SessionCursor(token: "x_\(UUID().uuidString)") == nil)
    }
}
