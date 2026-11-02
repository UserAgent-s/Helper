import Foundation
import Testing
@testable import Domain

final class FakeAnswerSession: AnswerSessionControlling, @unchecked Sendable {
    let broadcaster = EventBroadcaster<AnswerStreamEvent>()
    private let lock = NSLock()
    private var resets = 0

    func streamEvents() -> AsyncStream<AnswerStreamEvent> { broadcaster.subscribe() }
    func resetContext() async { lock.withLock { resets += 1 } }
    func emit(_ event: AnswerStreamEvent) { broadcaster.yield(event) }
    var resetCount: Int { lock.withLock { resets } }
}

final class ScriptedHintExpander: HintExpanding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [HintExpansionRequest] = []
    var deltas: [String]
    var error: Error?

    init(deltas: [String], error: Error? = nil) {
        self.deltas = deltas
        self.error = error
    }

    var requests: [HintExpansionRequest] { lock.withLock { calls } }

    func expand(_ request: HintExpansionRequest) -> AsyncThrowingStream<String, Error> {
        lock.withLock { calls.append(request) }
        let deltas = self.deltas
        let error = self.error
        return AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(delta) }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }
}

actor RecordingQuestionAnswerRepository: QuestionAnswerRepository {
    private(set) var saved: [QuestionAnswerPair] = []
    var preloaded: [QuestionAnswerPair] = []

    func seed(_ pairs: [QuestionAnswerPair]) { preloaded = pairs }
    func save(_ pair: QuestionAnswerPair) async throws { saved.append(pair) }
    func delete(id: UUID) async throws {}
    func deleteAll() async throws {}
    func history(limit: Int) async throws -> [QuestionAnswerPair] { Array(preloaded.prefix(limit)) }
    func search(query: String) async throws -> [QuestionAnswerPair] { [] }
}

actor HintEventCollector {
    private(set) var events: [HintFeedEvent] = []
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncStream<HintFeedEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                await self?.append(event)
            }
        }
    }

    private func append(_ event: HintFeedEvent) { events.append(event) }

    func waitUntil(timeout: Duration = .seconds(2), _ predicate: @Sendable ([HintFeedEvent]) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate(events) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(events)
    }
}

private func makePair(id: UUID = UUID(), question: String?, answer: String, status: AnswerRecordStatus, expansion: String? = nil, askedAt: Date = Date()) -> QuestionAnswerPair {
    QuestionAnswerPair(id: id, askedAt: askedAt, sourceAppBundleID: nil, questionText: question, contextWindowStartedAt: askedAt, contextWindowDurationMs: 0, triggerKind: .automatic, answerText: answer, modelID: "m", responseID: id.uuidString, expansionText: expansion, status: status)
}

@Suite struct HintFeedTests {
    @Test func streamingThenCompletedProducesOneHintAndSnapshotForLateSubscriber() async throws {
        let session = FakeAnswerSession()
        let feed = HintFeed(answers: session)
        await feed.start()
        let collector = HintEventCollector()
        await collector.start(feed.events())
        _ = await collector.waitUntil { events in events.contains { if case .snapshot = $0 { return true }; return false } }

        session.emit(.streaming(text: "Redis"))
        session.emit(.streaming(text: "Redis with TTL"))
        session.emit(.completed(finalText: "Redis with TTL."))
        let done = await collector.waitUntil { events in events.contains { if case .hintCompleted = $0 { return true }; return false } }
        #expect(done)

        let hints = await feed.currentHints
        #expect(hints.count == 1)
        #expect(hints.first?.text == "Redis with TTL.")
        #expect(hints.first?.status == .completed)
        let events = await collector.events
        #expect(events.contains { if case .hintStarted(let hint) = $0 { return hint.text == "Redis" }; return false })
        #expect(events.contains { if case .hintUpdated(let hint) = $0 { return hint.text == "Redis with TTL" }; return false })

        let late = HintEventCollector()
        await late.start(feed.events())
        let gotSnapshot = await late.waitUntil { events in
            events.contains { if case .snapshot(let hints, _) = $0 { return hints.count == 1 && hints[0].text == "Redis with TTL." }; return false }
        }
        #expect(gotSnapshot)
    }

    @Test func cancelledBeforeAnyTextCreatesNothingAndMidStreamMarksFailed() async {
        let session = FakeAnswerSession()
        let feed = HintFeed(answers: session)
        await feed.start()
        let collector = HintEventCollector()
        await collector.start(feed.events())
        session.emit(.manualResponsePending)
        session.emit(.cancelled)
        session.emit(.streaming(text: "partial"))
        session.emit(.cancelled)
        let done = await collector.waitUntil { events in events.contains { if case .hintUpdated(let hint) = $0 { return hint.status == .failed("cancelled") }; return false } }
        #expect(done)
        let hints = await feed.currentHints
        #expect(hints.count == 1)
        #expect(hints.first?.text == "partial")
    }

    @Test func questionAttachesFromStreamingDraftAndFollowsLaterUpdates() async {
        let session = FakeAnswerSession()
        let pairs = EventBroadcaster<QuestionAnswerPair>()
        let feed = HintFeed(answers: session)
        await feed.start(pairUpdates: pairs.subscribe())
        let collector = HintEventCollector()
        await collector.start(feed.events())

        session.emit(.streaming(text: "Use idempotency keys"))
        _ = await collector.waitUntil { events in events.contains { if case .hintStarted = $0 { return true }; return false } }
        let pairID = UUID()
        pairs.yield(makePair(id: pairID, question: "How to avoid double charges?", answer: "", status: .answerStreaming))
        let attached = await collector.waitUntil { events in events.contains { if case .hintUpdated(let hint) = $0 { return hint.question == "How to avoid double charges?" }; return false } }
        #expect(attached)

        session.emit(.completed(finalText: "Use idempotency keys."))
        pairs.yield(makePair(id: pairID, question: "How do you avoid double charges?", answer: "Use idempotency keys.", status: .completed))
        let updated = await collector.waitUntil { events in events.contains { if case .hintUpdated(let hint) = $0 { return hint.question == "How do you avoid double charges?" }; return false } }
        #expect(updated)
        #expect(await feed.currentHints.first?.pairID == pairID)
    }

    @Test func questionAttachesByAnswerTextWhenTranscriptionFinishesLater() async {
        let session = FakeAnswerSession()
        let pairs = EventBroadcaster<QuestionAnswerPair>()
        let feed = HintFeed(answers: session)
        await feed.start(pairUpdates: pairs.subscribe())
        let collector = HintEventCollector()
        await collector.start(feed.events())
        session.emit(.streaming(text: "Sharding by tenant"))
        session.emit(.completed(finalText: "Sharding by tenant."))
        _ = await collector.waitUntil { events in events.contains { if case .hintCompleted = $0 { return true }; return false } }
        let pairID = UUID()
        pairs.yield(makePair(id: pairID, question: nil, answer: "Sharding by tenant.", status: .completed))
        pairs.yield(makePair(id: pairID, question: "How would you scale writes?", answer: "Sharding by tenant.", status: .completed))
        let attached = await collector.waitUntil { events in events.contains { if case .hintUpdated(let hint) = $0 { return hint.question == "How would you scale writes?" && hint.pairID == pairID }; return false } }
        #expect(attached)
    }

    @Test func expandStreamsOncePersistsAndIgnoresRepeatedRequests() async {
        let session = FakeAnswerSession()
        let pairs = EventBroadcaster<QuestionAnswerPair>()
        let expander = ScriptedHintExpander(deltas: ["Because ", "latency."])
        let repository = RecordingQuestionAnswerRepository()
        let feed = HintFeed(answers: session, expander: expander, repository: repository)
        await feed.start(pairUpdates: pairs.subscribe())
        let collector = HintEventCollector()
        await collector.start(feed.events())
        session.emit(.streaming(text: "Redis"))
        session.emit(.completed(finalText: "Redis."))
        _ = await collector.waitUntil { events in events.contains { if case .hintCompleted = $0 { return true }; return false } }
        let pairID = UUID()
        pairs.yield(makePair(id: pairID, question: "Why Redis?", answer: "Redis.", status: .completed))
        _ = await collector.waitUntil { events in events.contains { if case .hintUpdated(let hint) = $0 { return hint.pairID == pairID }; return false } }

        let hintID = await feed.currentHints.first!.id
        await feed.expand(hintID: hintID)
        let completed = await collector.waitUntil { events in events.contains { if case .expansionUpdated(_, let expansion) = $0 { return expansion.status == .completed && expansion.text == "Because latency." }; return false } }
        #expect(completed)
        await feed.expand(hintID: hintID)
        #expect(expander.requests.count == 1)
        #expect(expander.requests.first?.question == "Why Redis?")
        #expect(expander.requests.first?.answer == "Redis.")
        let saved = await repository.saved
        #expect(saved.last?.id == pairID)
        #expect(saved.last?.expansionText == "Because latency.")
        #expect(await feed.currentHints.first?.text == "Redis.")
    }

    @Test func expansionFailureKeepsInstantHintIntact() async {
        let session = FakeAnswerSession()
        let expander = ScriptedHintExpander(deltas: ["partial"], error: AnswerProviderError.missingAPIKey(.anthropicClaude))
        let feed = HintFeed(answers: session, expander: expander)
        await feed.start()
        let collector = HintEventCollector()
        await collector.start(feed.events())
        session.emit(.streaming(text: "Instant"))
        session.emit(.completed(finalText: "Instant."))
        _ = await collector.waitUntil { events in events.contains { if case .hintCompleted = $0 { return true }; return false } }
        let hintID = await feed.currentHints.first!.id
        await feed.expand(hintID: hintID)
        let failed = await collector.waitUntil { events in events.contains { if case .expansionUpdated(_, let expansion) = $0 { if case .failed = expansion.status { return true } }; return false } }
        #expect(failed)
        let hint = await feed.currentHints.first
        #expect(hint?.text == "Instant.")
        #expect(hint?.expansion?.text == "partial")
    }

    @Test func historyLoadsPreviousSessionHintsWithExpansions() async {
        let session = FakeAnswerSession()
        let repository = RecordingQuestionAnswerRepository()
        let now = Date()
        await repository.seed([
            makePair(question: "q2", answer: "a2", status: .completed, expansion: "deep a2", askedAt: now),
            makePair(question: "q1", answer: "a1", status: .completed, askedAt: now.addingTimeInterval(-60)),
            makePair(question: "cancelled", answer: "x", status: .cancelled, askedAt: now.addingTimeInterval(-30)),
        ])
        let feed = HintFeed(answers: session, repository: repository)
        await feed.loadHistory(limit: 10)
        let hints = await feed.currentHints
        #expect(hints.map(\.text) == ["a1", "a2"])
        #expect(hints.allSatisfy { $0.fromPreviousSession })
        #expect(hints.last?.expansion?.text == "deep a2")
    }

    @Test func sessionStateFollowsModeAndConfiguration() async {
        let session = FakeAnswerSession()
        let modes = EventBroadcaster<ModeState>()
        let feed = HintFeed(answers: session, configurationProvider: { .claudeTest() })
        await feed.start(modeUpdates: modes.subscribe(), initialMode: .initialPassive)
        let collector = HintEventCollector()
        await collector.start(feed.events())
        modes.yield(ModeState(mode: .answers, phase: .active, startedAt: Date(), userFacingError: nil))
        let configured = await collector.waitUntil { events in events.contains { if case .sessionChanged(let state) = $0 { return state.phase == .collectingContext && state.provider == .anthropicClaude && state.modelID == "claude-opus-5-5" }; return false } }
        #expect(configured)
        session.emit(.streaming(text: "x"))
        let streaming = await collector.waitUntil { events in events.contains { if case .sessionChanged(let state) = $0 { return state.phase == .streaming }; return false } }
        #expect(streaming)
        modes.yield(.initialPassive)
        let inactive = await collector.waitUntil { events in events.contains { if case .sessionChanged(let state) = $0 { return state.mode == .passive && state.phase == .inactive && state.provider == nil }; return false } }
        #expect(inactive)
    }

    @Test func modeFailureIsExposedAsShortDiagnosticCode() async {
        let session = FakeAnswerSession()
        let modes = EventBroadcaster<ModeState>()
        let feed = HintFeed(answers: session)
        await feed.start(modeUpdates: modes.subscribe())
        let collector = HintEventCollector()
        await collector.start(feed.events())
        modes.yield(ModeState(mode: .passive, phase: .idle, startedAt: nil, userFacingError: .provider(.missingAPIKey(.openAIRealtime))))
        let seen = await collector.waitUntil { events in events.contains { if case .sessionChanged(let state) = $0 { return state.errorDescription == "missing_api_key" }; return false } }
        #expect(seen)
        #expect(ModeFailureReason.permissionDenied(.screenRecording).diagnosticCode == "permission_screen_recording")
        #expect(ModeFailureReason.targetApplicationNotRunning(bundleID: "x").diagnosticCode == "target_app_not_running")
    }

    @Test func noContextProducesNotice() async {
        let session = FakeAnswerSession()
        let feed = HintFeed(answers: session)
        await feed.start()
        let collector = HintEventCollector()
        await collector.start(feed.events())
        session.emit(.noContext)
        let noticed = await collector.waitUntil { events in events.contains { $0 == .notice(.noContext) } }
        #expect(noticed)
    }
}

@Suite struct ExpansionInstructionsTests {
    @Test func expansionInstructionsCarryAreasKnowledgeAndFormatWithoutTranscriptRules() {
        let knowledge = KnowledgeContextBuilder.build([KnowledgeNote(title: "Harness", content: "Built an eval loop")])
        let text = AnswerInstructionsBuilder.expansionInstructions(domains: [ExpertDomainPresets.systemDesign], candidate: CandidateProfile(primaryStack: "PHP"), knowledge: knowledge)
        #expect(text.contains("asked for a deeper explanation"))
        #expect(text.contains("## System Design"))
        #expect(text.contains("Built an eval loop"))
        #expect(text.contains("PHP"))
        #expect(text.contains("Stay under 350 words"))
        #expect(!text.contains("TRIGGER: automatic"))
        #expect(!text.contains(AnswerInstructionsBuilder.waitForQuestionSentinel))
    }

    @Test func expansionUserMessageOmitsUnknownQuestion() {
        let withQuestion = AnswerInstructionsBuilder.expansionUserMessage(question: "Why?", answer: "Because.")
        #expect(withQuestion.contains("<question>\nWhy?\n</question>"))
        #expect(withQuestion.contains("<short_answer>\nBecause.\n</short_answer>"))
        let without = AnswerInstructionsBuilder.expansionUserMessage(question: "  ", answer: "Because.")
        #expect(!without.contains("<question>"))
    }

    @Test func textAnswerExpanderSendsExpansionMessageInsteadOfTranscript() async throws {
        let generator = FakeTextAnswerGenerator(scripts: [.text(["Deep ", "dive"])])
        let expander = TextAnswerHintExpander(generator: generator) {
            TextAnswerHintExpander.Settings(modelID: "claude-opus-5-5", systemInstructions: "SYS", maxOutputTokens: 1024, reasoningEffort: nil, useServerSideFallback: false)
        }
        var collected = ""
        for try await delta in expander.expand(HintExpansionRequest(hintID: UUID(), question: "Q?", answer: "A.")) {
            collected += delta
        }
        #expect(collected == "Deep dive")
        let request = generator.requests.first
        #expect(request?.userMessage?.contains("<short_answer>") == true)
        #expect(request?.resolvedUserMessage.contains("<transcript>") == false)
        #expect(request?.systemInstructions == "SYS")
    }
}
