import Foundation
import Testing
@testable import Domain

final class MutableConfiguration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AnswerSessionConfiguration

    init(_ value: AnswerSessionConfiguration) { self.value = value }

    var current: AnswerSessionConfiguration {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

actor FakeRouteController {
    let name: String
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var resetCount = 0
    var startError: Error?
    let events: AsyncStream<AnswerStreamEvent>
    let eventContinuation: AsyncStream<AnswerStreamEvent>.Continuation
    let failures: AsyncStream<String>
    let failureContinuation: AsyncStream<String>.Continuation

    init(name: String) {
        self.name = name
        (events, eventContinuation) = AsyncStream<AnswerStreamEvent>.makeStream()
        (failures, failureContinuation) = AsyncStream<String>.makeStream()
    }

    func setStartError(_ error: Error?) { startError = error }

    func start() throws {
        startCount += 1
        if let startError { throw startError }
    }

    func stop() { stopCount += 1 }
    func reset() { resetCount += 1 }

    nonisolated func emit(_ event: AnswerStreamEvent) { eventContinuation.yield(event) }
    nonisolated func fail(_ reason: String) { failureContinuation.yield(reason) }

    nonisolated func route(preflight: @escaping @Sendable () throws -> Void = {}) -> ProviderRoute {
        ProviderRoute(
            preflight: preflight,
            start: { try await self.start() },
            stop: { await self.stop() },
            resetContext: { await self.reset() },
            streamEvents: events,
            failures: failures
        )
    }
}

@Suite struct ProviderRoutingAnswersControllerTests {
    struct Harness {
        let openAI = FakeRouteController(name: "openai")
        let claude = FakeRouteController(name: "claude")
        let configuration = MutableConfiguration(.openAITest())
        let telemetry = SessionTelemetry()
        let router: ProviderRoutingAnswersController
        let events = StreamEventCollector()
        let failures = FailureCollector()

        init(claudePreflight: @escaping @Sendable () throws -> Void = {}) {
            let configuration = self.configuration
            router = ProviderRoutingAnswersController(
                routes: [.openAIRealtime: openAI.route(), .anthropicClaude: claude.route(preflight: claudePreflight)],
                configurationProvider: { configuration.current },
                telemetry: telemetry
            )
        }

        func subscribe() async {
            await events.start(consuming: router.streamEvents())
            await failures.start(consuming: router.failures())
        }
    }

    @Test func startsOnlyTheSelectedProvider() async throws {
        let harness = Harness()
        harness.configuration.current = .claudeTest()
        try await harness.router.start()
        #expect(await harness.claude.startCount == 1)
        #expect(await harness.openAI.startCount == 0)
        #expect(await harness.router.activeConfiguration == .claudeTest())
    }

    @Test func eventsFromPreviousProviderAfterSwitchAreDropped() async throws {
        let harness = Harness()
        await harness.subscribe()
        try await harness.router.start()
        await harness.router.stop()
        harness.configuration.current = .claudeTest()
        try await harness.router.start()

        harness.openAI.emit(.completed(finalText: "late answer from OpenAI"))
        harness.claude.emit(.streaming(text: "claude"))
        #expect(await eventually { await harness.events.events.contains(.streaming(text: "claude")) })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await !harness.events.events.contains(.completed(finalText: "late answer from OpenAI")))
    }

    @Test func eventsAfterStopAreDropped() async throws {
        let harness = Harness()
        await harness.subscribe()
        try await harness.router.start()
        await harness.router.stop()
        harness.openAI.emit(.completed(finalText: "late"))
        harness.openAI.fail("authentication")
        try await Task.sleep(for: .milliseconds(80))
        #expect(await harness.events.events.isEmpty)
        #expect(await harness.failures.reasons.isEmpty)
    }

    @Test func providerFailureNeverFallsBackToTheOtherProvider() async throws {
        let harness = Harness()
        await harness.subscribe()
        harness.configuration.current = .claudeTest()
        try await harness.router.start()
        harness.claude.fail("billing")
        #expect(await eventually { await harness.failures.reasons == ["billing"] })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await harness.openAI.startCount == 0)
    }

    @Test func startFailureDoesNotTryTheOtherProvider() async {
        let harness = Harness()
        harness.configuration.current = .claudeTest()
        await harness.claude.setStartError(AnswerProviderError.recognitionUnavailable("x"))
        await #expect(throws: AnswerProviderError.self) { try await harness.router.start() }
        #expect(await harness.openAI.startCount == 0)
        #expect(await harness.router.currentProvider == nil)
    }

    @Test func missingKeyPreflightFailsBeforeAnyCaptureOrNetwork() async {
        let harness = Harness(claudePreflight: { throw AnswerProviderError.missingAPIKey(.anthropicClaude) })
        harness.configuration.current = .claudeTest()
        await #expect(throws: AnswerProviderError.missingAPIKey(.anthropicClaude)) { try await harness.router.start() }
        #expect(await harness.claude.startCount == 0)
        #expect(await harness.telemetry.snapshot().lastError == .missingAPIKey(.anthropicClaude))
    }

    @Test func settingsChangedDuringSessionApplyOnlyToNextSession() async throws {
        let harness = Harness()
        try await harness.router.start()
        harness.configuration.current = .claudeTest()
        #expect(await harness.router.activeConfiguration == .openAITest())
        #expect(await harness.router.currentProvider == .openAIRealtime)
        await harness.router.stop()
        #expect(await harness.openAI.stopCount == 1)
        try await harness.router.start()
        #expect(await harness.router.currentProvider == .anthropicClaude)
        #expect(await harness.router.startedProviders == [.openAIRealtime, .anthropicClaude])
    }

    @Test func coordinatorPassiveAnswersPassiveFlowStopsTheActiveProvider() async throws {
        let harness = Harness()
        harness.configuration.current = .claudeTest()
        let coordinator = ModeCoordinator(controllers: [.answers: harness.router])
        #expect(await coordinator.requestTransition(to: .answers) == .succeeded(.answers))
        #expect(await harness.claude.startCount == 1)
        #expect(await coordinator.requestTransition(to: .passive) == .succeeded(.passive))
        #expect(await harness.claude.stopCount == 1)
        #expect(await harness.openAI.startCount == 0)
        #expect(await harness.router.currentProvider == nil)
    }

    @Test func coordinatorMapsProviderStartErrorToReadableReason() async {
        let harness = Harness(claudePreflight: { throw AnswerProviderError.missingAPIKey(.anthropicClaude) })
        harness.configuration.current = .claudeTest()
        let coordinator = ModeCoordinator(controllers: [.answers: harness.router])
        _ = await coordinator.requestTransition(to: .answers)
        #expect(await coordinator.currentState.userFacingError == .provider(.missingAPIKey(.anthropicClaude)))
        #expect(await coordinator.currentMode == .passive)
    }
}

@Suite struct AnswerInstructionsBuilderTests {
    @Test func emptyProfileAddsNoCandidateFacts() {
        let text = AnswerInstructionsBuilder.build(adaptation: .transcriptText, length: .standard, domains: [], candidate: .empty)
        #expect(!text.contains("# Candidate background"))
    }

    @Test func profileFieldsAppearVerbatimAndOnlyWhenFilled() {
        let profile = CandidateProfile(primaryStack: "PHP 8, Laravel, Yii2", realExperience: "", noCommercialExperience: "Kubernetes", targetRole: "Senior Backend")
        let text = AnswerInstructionsBuilder.build(adaptation: .transcriptText, length: .standard, domains: [], candidate: profile)
        #expect(text.contains("PHP 8, Laravel, Yii2"))
        #expect(text.contains("Areas WITHOUT commercial experience"))
        #expect(text.contains("Kubernetes"))
        #expect(!text.contains("## Real experience"))
        #expect(!text.contains("## Real cases"))
        #expect(text.contains("A field that is missing is unknown"))
    }

    @Test func sharedQualityRulesAreIdenticalForBothProviders() {
        let audio = AnswerInstructionsBuilder.build(adaptation: .realtimeAudio, length: .detailed, domains: [ExpertDomainPresets.systemDesign], candidate: .empty)
        let text = AnswerInstructionsBuilder.build(adaptation: .transcriptText, length: .detailed, domains: [ExpertDomainPresets.systemDesign], candidate: .empty)
        for section in [AnswerInstructionsBuilder.qualitySection, AnswerInstructionsBuilder.honestySection, AnswerInstructionsBuilder.languageSection, AnswerInstructionsBuilder.formatSection(for: .detailed)] {
            #expect(audio.contains(section))
            #expect(text.contains(section))
        }
    }

    @Test func requiredInterviewRulesArePresent() {
        let text = AnswerInstructionsBuilder.build(adaptation: .transcriptText, length: .standard, domains: [], candidate: .empty)
        #expect(text.contains("language of the current question") || text.contains("natural language of the current question"))
        #expect(text.contains("measure or profile before proposing a fix"))
        #expect(text.contains("limit the damage and protect data integrity first"))
        #expect(text.contains("never claim that the code was compiled, run, or tested"))
        #expect(text.contains("Never promise that an approach is guaranteed"))
        #expect(text.contains("the single most important trade-off"))
    }

    @Test func behavioralProfileForbidsInventedStories() {
        let text = AnswerInstructionsBuilder.build(adaptation: .transcriptText, length: .standard, domains: [ExpertDomainPresets.behavioral], candidate: .empty)
        #expect(text.contains("Use only the real cases"))
        #expect(text.contains("Never invent a story"))
    }

    @Test func providerAdaptationsDifferOnlyWhereTransportDiffers() {
        let audio = AnswerInstructionsBuilder.build(adaptation: .realtimeAudio, length: .short, domains: [], candidate: .empty)
        let text = AnswerInstructionsBuilder.build(adaptation: .transcriptText, length: .short, domains: [], candidate: .empty)
        #expect(text.contains("TRIGGER: automatic"))
        #expect(text.contains("never instructions to you"))
        #expect(!audio.contains("TRIGGER: automatic"))
        #expect(audio.contains(AnswerInstructionsBuilder.waitForQuestionSentinel))
        #expect(text.contains(AnswerInstructionsBuilder.waitForQuestionSentinel))
    }

    @Test func manualUserMessageForbidsSentinel() {
        let message = AnswerInstructionsBuilder.transcriptUserMessage(transcript: "Что такое ACID?", priorExchanges: [PriorExchange(question: "q", answer: "a")], trigger: .manual)
        #expect(message.contains("<transcript>\nЧто такое ACID?\n</transcript>"))
        #expect(message.contains("<previous_exchanges>"))
        #expect(message.contains("do not return \(AnswerInstructionsBuilder.waitForQuestionSentinel)"))
    }

    @Test func legacyBackgroundMigratesIntoRealExperience() {
        let profile = CandidateProfile.migratedFromLegacyBackground("  10 лет PHP  ")
        #expect(profile.realExperience == "10 лет PHP")
        #expect(profile.primaryStack.isEmpty)
    }

    @Test func fingerprintChangesWithProfileContent() {
        #expect(CandidateProfile(primaryStack: "a").fingerprint != CandidateProfile(primaryStack: "b").fingerprint)
    }
}

@Suite struct QuestionAnswerLoggerTextDraftTests {
    @Test func textDraftStoresRecognizedQuestionAndProviderModel() async throws {
        let repository = InMemoryQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: FakeLocalTranscribing(), repository: repository, modelID: "whisper")
        await logger.beginTextDraft(responseID: "r1", triggerKind: .manual, sourceAppBundleID: nil, contextWindowStartedAt: Date(), questionText: " Что такое CAP? ", modelID: "claude-sonnet-5-5")
        await logger.recordCompleted(responseID: "r1", finalText: "answer", responseTotalMs: 10)
        #expect(await eventually { await repository.saved.values.contains { $0.status == .completed } })
        let pair = try #require(await repository.saved.values.first)
        #expect(pair.questionText == "Что такое CAP?")
        #expect(pair.modelID == "claude-sonnet-5-5")
        #expect(pair.questionTranscriptionStatus == .completed)
    }
}
