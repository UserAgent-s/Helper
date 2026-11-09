import CompanionBridge
import CompanionProtocol
import Domain
import Foundation
import Testing

private actor FakeHistory: SessionHistoryQuerying {
    let header: SessionHeader
    let detailValue: SessionHistoryDetail?
    private(set) var cursors: [SessionCursor?] = []
    private(set) var queries: [String] = []
    private(set) var limits: [Int] = []
    var failing = false

    init(header: SessionHeader, detail: SessionHistoryDetail?) {
        self.header = header
        detailValue = detail
    }

    func setFailing() { failing = true }

    func list(limit: Int, after cursor: SessionCursor?) async throws -> SessionPage {
        if failing { throw CancellationError() }
        cursors.append(cursor)
        limits.append(limit)
        return SessionPage(headers: [header], nextCursor: SessionCursor(startedAt: header.startedAt, id: header.id))
    }

    func search(query: String, limit: Int) async throws -> [SessionSearchResult] {
        queries.append(query)
        let hit = SessionSearchHit(sessionID: header.id, source: .utterance, itemID: "u1", snippet: "про «Kafka»", occurredAt: header.startedAt, rank: -1)
        return [SessionSearchResult(sessionID: header.id, kind: .assistant, title: header.title, startedAt: header.startedAt, hits: [hit])]
    }

    func detail(sessionID: SessionID) async throws -> SessionHistoryDetail? {
        sessionID == header.id ? detailValue : nil
    }
}

@Suite struct CompanionBridgeHistoryTests {
    private let start = Date(timeIntervalSince1970: 1_762_696_400)

    private func fixture(utterances: [SessionUtterance] = []) -> (SessionHeader, SessionHistoryDetail) {
        let id = SessionID()
        let header = SessionHeader(id: id, kind: .assistant, title: "Звонок 15:00", startedAt: start, endedAt: start.addingTimeInterval(600), status: .completed, pinned: false, lastActivityAt: start, questionAnswerCount: 1, starCount: 1)
        let session = AssistantSession(id: id, kind: .assistant, title: "Звонок 15:00", startedAt: start, endedAt: start.addingTimeInterval(600), status: .completed, lastActivityAt: start, spans: [])
        let pair = QuestionAnswerPair(askedAt: start.addingTimeInterval(60), sourceAppBundleID: nil, questionText: "Что такое Kafka?", contextWindowStartedAt: start, contextWindowDurationMs: 0, triggerKind: .manual, answerText: "Лог", answerModelID: "gpt-realtime-2.1", responseID: "r1", status: .completed, sessionID: id)
        let detail = SessionDetail(
            session: session,
            utterances: utterances,
            questionAnswers: [pair],
            bookmarks: [SessionBookmark(sessionID: id, kind: .star, questionAnswerID: pair.id, markedAt: start.addingTimeInterval(70))],
            expansions: [
                SessionExpansion(id: "d1", questionAnswerID: pair.id, requestedAt: start.addingTimeInterval(80), modelID: "claude-sonnet-5-5", status: "completed", text: "Подробно"),
                SessionExpansion(id: "d2", questionAnswerID: nil, requestedAt: start.addingTimeInterval(90), modelID: "claude-sonnet-5-5", status: "completed", text: "Отдельно"),
            ],
            screenContexts: [SessionScreenContext(id: "s1", capturedAt: start.addingTimeInterval(30), application: "Xcode", windowTitle: nil, text: String(repeating: "x", count: 9000))]
        )
        return (header, SessionHistoryDetail(detail: detail, summary: nil))
    }

    @Test func historyCapabilityOnlyWithHistory() {
        let (header, detail) = fixture()
        #expect(!CompanionBridge(control: FakeDomainControl()).capabilities.contains("history.list"))
        let bridge = CompanionBridge(control: FakeDomainControl(), history: FakeHistory(header: header, detail: detail))
        #expect(bridge.capabilities.contains("history.list"))
        #expect(bridge.capabilities.contains("history.get"))
    }

    @Test func listMapsHeadersAndCursors() async throws {
        let (header, detail) = fixture()
        let history = FakeHistory(header: header, detail: detail)
        let bridge = CompanionBridge(control: FakeDomainControl(), history: history)

        guard case .page(let page) = await bridge.history(.historyList(.init())) else { Issue.record("no page"); return }
        #expect(page.items == [HistoryItem(sessionId: header.id.rawValue.uuidString, kind: "assistant", title: "Звонок 15:00", startedAt: 1_762_696_400_000, endedAt: 1_762_697_000_000, status: "completed", pinned: false, qaCount: 1, starCount: 1)])
        let next = try #require(page.nextCursor)
        _ = await bridge.history(.historyList(.init(cursor: next, limit: 20)))
        #expect(await history.cursors == [nil, SessionCursor(token: next)])
        #expect(await history.limits == [ClientCommand.HistoryList.defaultLimit, 20])
        #expect(await bridge.history(.historyList(.init(cursor: "garbage"))) == .rejected(code: "invalid_cursor"))

        guard case .page(let found) = await bridge.history(.historyList(.init(q: "  kafka  "))) else { Issue.record("no search"); return }
        #expect(found.q == "kafka")
        #expect(found.nextCursor == nil)
        #expect(found.items.first?.hits == [HistoryHit(source: "utterance", itemId: "u1", snippet: "про «Kafka»", at: 1_762_696_400_000)])
        #expect(found.items.first?.qaCount == nil)
        #expect(await history.queries == ["kafka"])

        await history.setFailing()
        #expect(await bridge.history(.historyList(.init())) == .rejected(code: "history_failed"))
        #expect(await CompanionBridge(control: FakeDomainControl()).history(.historyList(.init())) == .rejected(code: "not_available"))
    }

    @Test func getGroupsExpansionsAndCapsScreenText() async throws {
        let (header, detail) = fixture()
        let bridge = CompanionBridge(control: FakeDomainControl(), history: FakeHistory(header: header, detail: detail))
        guard case .session(let session) = await bridge.history(.historyGet(.init(sessionId: header.id.rawValue.uuidString))) else { Issue.record("no session"); return }
        #expect(session.qa.count == 1)
        #expect(session.qa[0].starred)
        #expect(session.qa[0].expansions.map(\.expansionId) == ["d1"])
        #expect(session.expansions.map(\.expansionId) == ["d2"])
        #expect(session.moments.first?.kind == .star)
        #expect(session.screens.first?.text.count == CompanionHistoryMapping.maxScreenTextLength)
        #expect(!session.truncated)
        #expect(await bridge.history(.historyGet(.init(sessionId: UUID().uuidString))) == .rejected(code: "unknown_session"))
        #expect(await bridge.history(.historyGet(.init(sessionId: "nope"))) == .rejected(code: "unknown_session"))
    }

    @Test func oversizedSessionKeepsPrefixOfTranscriptAndMarksTruncated() throws {
        let lines = (0..<400).map { index in
            SessionUtterance(id: "u\(index)", speaker: index.isMultiple(of: 2) ? .them : .me, origin: .realtimeInput, text: String(repeating: "слово ", count: 100), capturedAt: start.addingTimeInterval(TimeInterval(index)))
        }
        let (_, detail) = fixture(utterances: lines)
        let full = CompanionHistoryMapping.session(detail)
        let budget = 100_000
        let fitted = CompanionHistoryMapping.fitted(full, budget: budget)
        #expect(fitted.truncated)
        #expect(fitted.transcript.count > 0)
        #expect(fitted.transcript.count < lines.count)
        #expect(fitted.transcript.map(\.lineId) == Array(full.transcript.prefix(fitted.transcript.count)).map(\.lineId))
        #expect(try JSONEncoder().encode(fitted).count <= budget)
        #expect(try JSONEncoder().encode(full.withTranscript(Array(full.transcript.prefix(fitted.transcript.count + 1)), truncated: true)).count > budget)
        #expect(CompanionHistoryMapping.fitted(full) == full)
    }
}
