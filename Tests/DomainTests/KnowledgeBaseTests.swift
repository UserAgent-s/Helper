import Foundation
import Testing
@testable import Domain

@Suite struct KnowledgeBaseTests {
    @Test func onlyEnabledNotesAreIncluded() {
        let notes = [
            KnowledgeNote(title: "Resume", content: "Backend: PHP, Laravel"),
            KnowledgeNote(title: "Private", content: "do not send", isEnabled: false),
        ]
        let context = KnowledgeContextBuilder.build(notes)
        #expect(context.text.contains("## Resume\nBackend: PHP, Laravel"))
        #expect(!context.text.contains("do not send"))
        #expect(context.includedNoteCount == 1)
    }

    @Test func budgetTruncatesAndReportsInsteadOfSilentlyDropping() {
        let notes = [
            KnowledgeNote(title: "Big", content: String(repeating: "a", count: 900)),
            KnowledgeNote(title: "Next", content: String(repeating: "b", count: 900)),
        ]
        let context = KnowledgeContextBuilder.build(notes, budgetCharacters: 1_000)
        #expect(context.text.count <= 1_100)
        #expect(context.truncatedNoteCount >= 1)
        #expect(context.text.contains("[…truncated]") || context.includedNoteCount == 1)
    }

    @Test func recentAnswersUseOnlyCompletedPairsNewestLastAndBounded() {
        let now = Date()
        func pair(_ q: String, _ a: String, _ offset: TimeInterval, status: AnswerRecordStatus = .completed) -> QuestionAnswerPair {
            QuestionAnswerPair(askedAt: now.addingTimeInterval(offset), sourceAppBundleID: nil, questionText: q, contextWindowStartedAt: now, contextWindowDurationMs: 0, triggerKind: .automatic, answerText: a, modelID: "m", responseID: q, status: status)
        }
        let pairs = [pair("q1", "a1", -30), pair("q2", "a2", -20), pair("q3", "a3", -10), pair("cancelled", "x", -5, status: .cancelled), pair("q4", "", -1)]
        let exchanges = RecentAnswersMemory.exchanges(from: pairs, limit: 2)
        #expect(exchanges.map(\.question) == ["q2", "q3"])
        #expect(RecentAnswersMemory.exchanges(from: pairs, limit: 0).isEmpty)
    }

    @Test func instructionsCarryKnowledgeAndMemoryForBothProviders() {
        let knowledge = KnowledgeContextBuilder.build([KnowledgeNote(title: "Harness", content: "Built an eval loop for an LLM agent")])
        let memory = [PriorExchange(question: "Почему Redis?", answer: "Из-за latency.")]
        for adaptation in [InstructionsAdaptation.realtimeAudio, .transcriptText] {
            let text = AnswerInstructionsBuilder.build(adaptation: adaptation, length: .standard, domains: [], candidate: .empty, knowledge: knowledge, recentExchanges: memory)
            #expect(text.contains("# Personal knowledge base"))
            #expect(text.contains("Built an eval loop for an LLM agent"))
            #expect(text.contains("never extrapolate"))
            #expect(text.contains("Q: Почему Redis?"))
        }
        let empty = AnswerInstructionsBuilder.build(adaptation: .transcriptText, length: .standard, domains: [], candidate: .empty)
        #expect(!empty.contains("# Personal knowledge base"))
        #expect(!empty.contains("earlier sessions"))
    }

    @Test func liveContextFingerprintChangesWhenKnowledgeChanges() {
        let live = LiveAnswerContext()
        let before = live.fingerprint
        live.update(knowledge: KnowledgeContextBuilder.build([KnowledgeNote(title: "a", content: "b")]))
        #expect(live.fingerprint != before)
    }

    @Test func routerRefreshesContextBeforeCapturingConfiguration() async throws {
        let openAI = FakeRouteController(name: "openai")
        let order = CallRecorder()
        let router = ProviderRoutingAnswersController(
            routes: [.openAIRealtime: openAI.route()],
            configurationProvider: { .openAITest() },
            prepare: { await order.record("prepare") },
            telemetry: SessionTelemetry()
        )
        try await router.start()
        #expect(await order.events == ["prepare"])
        #expect(await openAI.startCount == 1)
    }
}
