import Foundation
import Testing
@testable import Domain

private actor CountingSummaries: SummaryGenerating {
    private(set) var calls: [MeetingID] = []
    var failure: (any Error)?

    func fail(with error: any Error) {
        failure = error
    }

    func summarize(meetingID: MeetingID, headers: SummaryMarkdownHeaders) async throws -> MeetingSummary {
        calls.append(meetingID)
        if let failure { throw failure }
        return MeetingSummary(meetingID: meetingID, modelID: "test", contentJSON: "{}", renderedMarkdown: "# Итог", generatedAt: Date(timeIntervalSince1970: 0))
    }
}

private actor RecordingSummaryStore: SummaryRepository {
    private(set) var saved: [MeetingSummary] = []

    func save(_ summary: MeetingSummary) async throws {
        saved.append(summary)
    }

    func fetch(meetingID: MeetingID) async throws -> MeetingSummary? {
        saved.last { $0.meetingID == meetingID }
    }
}

private struct SummaryUnavailable: Error {}

private let utc = TimeZone(identifier: "UTC")!
private let start = Date(timeIntervalSince1970: 1_762_700_400)

private func pair(_ question: String?, at offset: TimeInterval, status: AnswerRecordStatus = .completed) -> QuestionAnswerPair {
    QuestionAnswerPair(
        askedAt: start.addingTimeInterval(offset),
        sourceAppBundleID: nil,
        questionText: question,
        contextWindowStartedAt: start,
        contextWindowDurationMs: 0,
        triggerKind: .automatic,
        answerText: "ответ",
        answerModelID: "gpt-realtime-test",
        responseID: "r_\(Int(offset))",
        status: status
    )
}

private func detail(_ pairs: [QuestionAnswerPair]) -> SessionDetail {
    let id = SessionID()
    let session = AssistantSession(id: id, kind: .assistant, startedAt: start, status: .completed, lastActivityAt: start)
    return SessionDetail(session: session, utterances: [], questionAnswers: pairs, bookmarks: [], expansions: [], screenContexts: [])
}

@Suite struct SessionTitleHeuristicTests {
    @Test func titleHeuristicFallbacks() {
        #expect(SessionTitleHeuristic.title(for: detail([]), timeZone: utc) == "Звонок 15:00")
        #expect(SessionTitleHeuristic.title(for: detail([pair(nil, at: 5), pair("   \n ", at: 6)]), timeZone: utc) == "Звонок 15:00")
        #expect(SessionTitleHeuristic.title(for: detail([pair("Чем Kafka\n отличается от RabbitMQ?", at: 30), pair("Второй", at: 90)]), timeZone: utc) == "09.11 · Чем Kafka отличается от RabbitMQ?")
        #expect(SessionTitleHeuristic.title(for: detail([pair("Позже", at: 90), pair("Раньше", at: 10)]), timeZone: utc) == "09.11 · Раньше")
        let long = "Расскажите подробно, как вы проектировали систему биллинга с идемпотентными платежами и ретраями"
        let title = SessionTitleHeuristic.title(for: detail([pair(long, at: 1)]), timeZone: utc)
        #expect(title == "09.11 · Расскажите подробно, как вы проектировали систему биллинга…")
        #expect(title.count <= "09.11 · ".count + SessionTitleHeuristic.maxQuestionLength + 1)
        #expect(SessionTitleHeuristic.title(for: detail([]), timeZone: TimeZone(identifier: "Europe/Moscow")!) == "Звонок 18:00")
    }
}

@Suite struct SessionFinalizerTests {
    private struct Harness {
        let repository = InMemorySessionRepository()
        let summaries = CountingSummaries()
        let store = RecordingSummaryStore()
        let finalizer: SessionFinalizer

        init(autoSummary: Bool) {
            finalizer = SessionFinalizer(repository: repository, summaries: summaries, summaryStore: store, isAutoSummaryEnabled: { autoSummary }, timeZone: utc)
        }

        func completedSession(question: String? = "Как устроен Raft?") async throws -> SessionID {
            let session = try await repository.create(kind: .assistant, mode: .answers, at: start)
            try await repository.appendUtterance(SessionUtterance(id: "utt_1", speaker: .them, origin: .realtimeInput, text: "Как устроен Raft?", capturedAt: start.addingTimeInterval(3)), sessionID: session.id)
            if let question {
                await repository.setQuestionAnswers([pair(question, at: 4)], for: session.id)
            }
            try await repository.finish(sessionID: session.id, at: start.addingTimeInterval(600))
            return session.id
        }
    }

    @Test func finalizerNoNetworkWhenAutoSummaryOff() async throws {
        let harness = Harness(autoSummary: false)
        let id = try await harness.completedSession()
        await harness.finalizer.finalize(sessionID: id)
        await harness.finalizer.waitForPendingSummaries()
        #expect(await harness.summaries.calls.isEmpty)
        #expect(await harness.store.saved.isEmpty)
        let session = try #require(try await harness.repository.session(id: id))
        #expect(session.title == "09.11 · Как устроен Raft?")
        #expect(session.titleSource == .heuristic)
    }

    @Test func finalizerSummarizesOnlyWithOptIn() async throws {
        let harness = Harness(autoSummary: true)
        let id = try await harness.completedSession()
        await harness.finalizer.finalize(sessionID: id)
        await harness.finalizer.waitForPendingSummaries()
        #expect(await harness.summaries.calls == [id])
        #expect(await harness.store.saved.map(\.meetingID) == [id])
        #expect(await harness.finalizer.summarySuccessCount == 1)
    }

    @Test func finalizerSummaryFailureKeepsSessionCompleted() async throws {
        let harness = Harness(autoSummary: true)
        await harness.summaries.fail(with: SummaryUnavailable())
        let id = try await harness.completedSession()
        await harness.finalizer.finalize(sessionID: id)
        await harness.finalizer.waitForPendingSummaries()
        let session = try #require(try await harness.repository.session(id: id))
        #expect(session.status == .completed)
        #expect(session.title == "09.11 · Как устроен Raft?")
        #expect(await harness.store.saved.isEmpty)
        #expect(await harness.finalizer.summaryFailureCount == 1)
    }

    @Test func finalizerKeepsUserTitleAndRefreshesHeuristic() async throws {
        let harness = Harness(autoSummary: false)
        let id = try await harness.completedSession(question: nil)
        await harness.finalizer.finalize(sessionID: id)
        #expect(try await harness.repository.session(id: id)?.title == "Звонок 15:00")
        await harness.repository.setQuestionAnswers([pair("Что такое CRDT?", at: 700)], for: id)
        await harness.finalizer.finalize(sessionID: id)
        #expect(try await harness.repository.session(id: id)?.title == "09.11 · Что такое CRDT?")
        try await harness.repository.setTitle(sessionID: id, title: "Собеседование Acme", source: .user)
        await harness.finalizer.finalize(sessionID: id)
        #expect(try await harness.repository.session(id: id)?.title == "Собеседование Acme")
    }

    @Test func titlePresentImmediatelyAfterStop() async throws {
        let repository = InMemorySessionRepository()
        let modes = FakeSessionModes()
        let finalizer = SessionFinalizer(repository: repository, timeZone: utc)
        let coordinator = SessionCoordinator(
            repository: repository,
            modes: modes,
            now: { start },
            idleCheckInterval: .seconds(3_600),
            afterFinish: { await finalizer.finalize(sessionID: $0) }
        )
        let events = coordinator.events(subscriber: "test")
        let id = try await coordinator.start()
        try await repository.appendUtterance(SessionUtterance(id: "utt_1", speaker: .them, origin: .realtimeInput, text: "вопрос", capturedAt: start), sessionID: id)
        let titleAtStop = Task { () -> String? in
            for await event in events {
                if case .stopped(let stopped, _) = event, stopped == id {
                    return try? await repository.session(id: id)?.title
                }
            }
            return nil
        }
        await coordinator.stop()
        #expect(try await repository.session(id: id)?.title == "Звонок 15:00")
        #expect(await titleAtStop.value == "Звонок 15:00")
    }

    @Test func discardedSessionIsNotFinalized() async throws {
        let repository = InMemorySessionRepository()
        let finalized = LockedIDs()
        let coordinator = SessionCoordinator(
            repository: repository,
            modes: FakeSessionModes(),
            idleCheckInterval: .seconds(3_600),
            afterFinish: { finalized.append($0) }
        )
        try await coordinator.start()
        await coordinator.stop()
        #expect(finalized.values.isEmpty)
    }
}

private final class LockedIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SessionID] = []

    func append(_ id: SessionID) {
        lock.withLock { stored.append(id) }
    }

    var values: [SessionID] {
        lock.withLock { stored }
    }
}
