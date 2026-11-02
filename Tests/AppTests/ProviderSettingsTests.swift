import Foundation
import Testing
import Domain
import Diagnostics
import SecurityStore
@testable import MeetingAssistant

private func freshDefaults() -> UserDefaults {
    let suite = "com.local.MeetingAssistant.tests.settings.\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}

private final class IdleModeController: ModeController, Sendable {
    private let stream: AsyncStream<String>
    init() { (stream, _) = AsyncStream<String>.makeStream() }
    func start() async throws {}
    func stop() async {}
    nonisolated func failures() -> AsyncStream<String> { stream }
}

@MainActor
@Suite struct ProviderSettingsTests {
    @Test func providerModelAndProfileSurviveRelaunch() {
        let defaults = freshDefaults()
        let first = AppSettingsStore(defaults: defaults)
        first.answerProvider = .anthropicClaude
        first.setModelSelection(AnswerModelSelection(provider: .anthropicClaude, modelID: "claude-sonnet-5-5", isCustom: false))
        first.setModelSelection(AnswerModelSelection(provider: .openAIRealtime, modelID: "gpt-realtime-next-preview", isCustom: true))
        first.answerTriggerMode = .manualOnly
        first.answerProfile = .systemDesign
        first.candidateProfile = CandidateProfile(primaryStack: "PHP, Laravel", targetRole: "Architect")
        first.spendLimitUSD = 1.5
        first.spendLimitMode = .stopSession

        let relaunched = AppSettingsStore(defaults: defaults)
        #expect(relaunched.answerProvider == .anthropicClaude)
        #expect(relaunched.modelSelection(for: .anthropicClaude) == AnswerModelSelection(provider: .anthropicClaude, modelID: "claude-sonnet-5-5", isCustom: false))
        #expect(relaunched.modelSelection(for: .openAIRealtime) == AnswerModelSelection(provider: .openAIRealtime, modelID: "gpt-realtime-next-preview", isCustom: true))
        #expect(relaunched.answerTriggerMode == .manualOnly)
        #expect(relaunched.answerProfile == .systemDesign)
        #expect(relaunched.candidateProfile.primaryStack == "PHP, Laravel")
        #expect(relaunched.spendPolicy == SpendPolicy(limitUSD: 1.5, mode: .stopSession))
    }

    @Test func defaultsAreVerifiedCatalogModels() {
        let store = AppSettingsStore(defaults: freshDefaults())
        #expect(store.answerProvider == .openAIRealtime)
        #expect(store.modelSelection(for: .openAIRealtime).modelID == AnswerModelCatalog.defaultOpenAIModelID)
        #expect(store.modelSelection(for: .anthropicClaude).modelID == AnswerModelCatalog.defaultAnthropicModelID)
        #expect(store.spendLimitUSD == nil)
    }

    @Test func malformedStoredModelFallsBackToCatalogDefault() {
        let defaults = freshDefaults()
        defaults.set("bad id with spaces", forKey: "com.local.MeetingAssistant.settings.anthropicModelID")
        #expect(AppSettingsStore(defaults: defaults).modelSelection(for: .anthropicClaude).modelID == AnswerModelCatalog.defaultAnthropicModelID)
    }

    @Test func legacyBackgroundBecomesRealExperienceWithoutInventingOtherFields() {
        let defaults = freshDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.backgroundContext = "Backend на PHP, AWS SQS/Lambda"
        let profile = store.candidateProfile
        #expect(profile.realExperience == "Backend на PHP, AWS SQS/Lambda")
        #expect(profile.primaryStack.isEmpty)
        #expect(profile.realCases.isEmpty)
        #expect(profile.targetRole.isEmpty)
    }

    @Test func claudeSettingsUseTextAdaptationAndOnlyVerifiedParameters() {
        let store = AppSettingsStore(defaults: freshDefaults())
        store.setModelSelection(AnswerModelSelection(provider: .anthropicClaude, modelID: "claude-unlisted-9", isCustom: true))
        let settings = store.transcribedSessionSettings()
        #expect(settings.modelID == "claude-unlisted-9")
        #expect(settings.reasoningEffort == nil)
        #expect(settings.useServerSideFallback == false)
        #expect(settings.systemInstructions.contains("TRIGGER: automatic"))

        store.setModelSelection(AnswerModelSelection(provider: .anthropicClaude, modelID: "claude-opus-5-5", isCustom: false))
        let verified = store.transcribedSessionSettings()
        #expect(verified.reasoningEffort == "low")
        #expect(verified.useServerSideFallback == true)
    }

    @Test func realtimeOptionsFollowSelectedModel() {
        let store = AppSettingsStore(defaults: freshDefaults())
        store.setModelSelection(AnswerModelSelection(provider: .openAIRealtime, modelID: "gpt-realtime-mini", isCustom: false))
        #expect(store.realtimeSessionOptions().model == "gpt-realtime-mini")
        #expect(store.realtimeSessionOptions().reasoningEffort == nil)
    }

    @Test func providerChangeIsBlockedOutsidePassive() async throws {
        let environment = makeIsolatedTestEnvironment()
        let root = CompositionRoot(environment: environment)
        let coordinator = ModeCoordinator(controllers: [.answers: IdleModeController()])
        let modeViewModel = ModeSwitcherViewModel(modeCoordinator: coordinator)
        let viewModel = SettingsViewModel(
            settingsStore: root.settingsStore,
            secretStores: root.secretStores,
            preferredAudioSource: root.preferredAudioSource,
            permissionsChecking: root.permissionsChecking,
            recordingsDirectory: root.recordingsDirectory,
            modeViewModel: modeViewModel,
            sessionStatus: root.sessionStatusViewModel,
            overlayPreferences: OverlayPreferencesStore(defaults: environment.defaults)
        )
        viewModel.answerProvider = .anthropicClaude
        #expect(root.settingsStore.answerProvider == .anthropicClaude)

        _ = await coordinator.requestTransition(to: .answers)
        for _ in 0..<50 where modeViewModel.currentMode != .answers {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(modeViewModel.currentMode == .answers)
        viewModel.answerProvider = .openAIRealtime
        #expect(root.settingsStore.answerProvider == .anthropicClaude)
        #expect(viewModel.providerChangeBlocked)
        viewModel.modelPickerTag = "claude-haiku-5-5"
        #expect(root.settingsStore.modelSelection(for: .anthropicClaude).modelID == AnswerModelCatalog.defaultAnthropicModelID)
    }

    @Test func diagnosticsExcludeConversationAndProfileByDefault() async throws {
        let environment = makeIsolatedTestEnvironment()
        let root = CompositionRoot(environment: environment)
        root.settingsStore.candidateProfile = CandidateProfile(realExperience: "SECRET-PROFILE-MARKER")
        try await root.questionAnswerRepository.save(QuestionAnswerPair(
            askedAt: Date(), sourceAppBundleID: nil, questionText: "SECRET-QUESTION-MARKER",
            contextWindowStartedAt: Date(), contextWindowDurationMs: 0, triggerKind: .manual,
            answerText: "SECRET-ANSWER-MARKER", modelID: "m", responseID: "r", status: .completed
        ))
        let telemetry = SessionTelemetrySnapshot()
        let snapshot = await DiagnosticsExporter.makeSnapshot(
            mode: .passive, phase: .idle, permissionsChecking: root.permissionsChecking,
            latencyRecorder: InMemoryLatencyRecorder(), telemetry: telemetry, includeContent: false,
            questionAnswerRepository: root.questionAnswerRepository, meetingRepository: root.meetingRepository
        )
        let json = String(decoding: try DiagnosticsExporter.encodeJSON(snapshot), as: UTF8.self)
        #expect(!json.contains("SECRET-QUESTION-MARKER"))
        #expect(!json.contains("SECRET-ANSWER-MARKER"))
        #expect(!json.contains("SECRET-PROFILE-MARKER"))
        #expect(json.contains("\"includesConversationContent\" : false"))

        let optIn = await DiagnosticsExporter.makeSnapshot(
            mode: .passive, phase: .idle, permissionsChecking: root.permissionsChecking,
            latencyRecorder: InMemoryLatencyRecorder(), telemetry: telemetry, includeContent: true,
            questionAnswerRepository: root.questionAnswerRepository, meetingRepository: root.meetingRepository
        )
        #expect(String(decoding: try DiagnosticsExporter.encodeJSON(optIn), as: UTF8.self).contains("SECRET-QUESTION-MARKER"))
    }

    @Test func pendingSettingsAreFlaggedOnlyWhileASessionUsesOlderValues() async throws {
        let root = CompositionRoot(environment: makeIsolatedTestEnvironment())
        root.sessionStatusViewModel.refreshPendingState()
        root.settingsStore.answerLength = .detailed
        root.sessionStatusViewModel.refreshPendingState()
        #expect(root.sessionStatusViewModel.hasUnappliedSettings == false)
    }
}

@MainActor
@Suite struct KnowledgeIntegrationTests {
    @Test func importedNotesAndPastAnswersReachAnswersInstructions() async throws {
        let root = CompositionRoot(environment: makeIsolatedTestEnvironment())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString).md")
        try "Senior backend: PHP, Yii2, AWS Lambda".write(to: file, atomically: true, encoding: .utf8)
        await root.knowledgeBaseViewModel.importFiles([file])
        try await root.questionAnswerRepository.save(QuestionAnswerPair(
            askedAt: Date(), sourceAppBundleID: nil, questionText: "Как вы масштабировали очередь?",
            contextWindowStartedAt: Date(), contextWindowDurationMs: 0, triggerKind: .automatic,
            answerText: "Партиционированием по ключу.", modelID: "m", responseID: "r1", status: .completed
        ))
        await CompositionRoot.refreshLiveContext(settingsStore: root.settingsStore, notes: root.knowledgeNoteRepository, history: root.questionAnswerRepository)
        let realtime = root.settingsStore.instructions(for: .realtimeAudio)
        let claude = root.settingsStore.transcribedSessionSettings().systemInstructions
        for text in [realtime, claude] {
            #expect(text.contains("Senior backend: PHP, Yii2, AWS Lambda"))
            #expect(text.contains("Как вы масштабировали очередь?"))
        }
    }

    @Test func disablingMemoryRemovesPastAnswers() async throws {
        let root = CompositionRoot(environment: makeIsolatedTestEnvironment())
        root.settingsStore.answersMemoryCount = 0
        try await root.questionAnswerRepository.save(QuestionAnswerPair(
            askedAt: Date(), sourceAppBundleID: nil, questionText: "MEMORY-MARKER",
            contextWindowStartedAt: Date(), contextWindowDurationMs: 0, triggerKind: .automatic,
            answerText: "x", modelID: "m", responseID: "r2", status: .completed
        ))
        await CompositionRoot.refreshLiveContext(settingsStore: root.settingsStore, notes: root.knowledgeNoteRepository, history: root.questionAnswerRepository)
        #expect(!root.settingsStore.instructions(for: .transcriptText).contains("MEMORY-MARKER"))
    }

    @Test func pdfAndUnsupportedFilesAreHandled() throws {
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).bin")
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: bad)
        guard case .failure = KnowledgeBaseViewModel.extractText(from: bad) else {
            Issue.record("binary file must not import")
            return
        }
    }
}
