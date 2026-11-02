import Foundation
import Domain
import AudioCapture
import RealtimeClient
import AnthropicClient
import Transcription
import Persistence
import SecurityStore
import Diagnostics
import Summary
import OverlayReducer

struct TelemetryLatencyRecorder: LatencyRecording {
    let base: InMemoryLatencyRecorder
    let telemetry: SessionTelemetry

    func record(_ metric: LatencyMetric) async {
        await base.record(metric)
        switch metric {
        case .speechEndToFirstDeltaMs(let value), .manualTriggerToFirstDeltaMs(let value):
            await telemetry.recordQuestionToFirstText(ms: value)
        default:
            break
        }
    }
}

@MainActor
final class CompositionRoot {
    let environment: AppEnvironment
    let modeCoordinator: ModeCoordinator
    let manualAnswerTrigger: ManualAnswerTrigger
    let preferredAudioSource: any PreferredAudioSourceStoring
    let permissionsChecking: any PermissionsChecking

    let answersSystemAudioCapturing: any SystemAudioCapturing
    let transcribedAnswersSystemAudioCapturing: any SystemAudioCapturing
    let recordingSystemAudioCapturing: any SystemAudioCapturing
    let microphoneCapturing: any MicrophoneCapturing
    let realtimeAnswering: any RealtimeAnswering
    let localTranscribing: any LocalTranscribing
    let whisperKitTranscribing: WhisperKitTranscribing
    let meetingRepository: any MeetingRepository
    let questionAnswerRepository: any QuestionAnswerRepository
    let summaryRepository: any SummaryRepository
    let knowledgeNoteRepository: any KnowledgeNoteRepository
    let summaryGenerating: any SummaryGenerating
    let secretStoring: any SecretStoring
    let secretStores: [AnswerProvider: any SecretStoring]
    let latencyRecording: InMemoryLatencyRecorder
    let sessionTelemetry: SessionTelemetry
    let settingsStore: AppSettingsStore
    let recordingsDirectory: URL
    private var desktopExportTask: Task<Void, Never>?

    let answersRingBuffer: AnswersRingBuffer
    let questionAnswerLogger: QuestionAnswerLogger

    let recordingModeController: RecordingModeController

    let modeViewModel: ModeSwitcherViewModel
    let answersModeController: AnswersModeController
    let transcribedAnswersModeController: TranscribedAnswersModeController
    let answersRouter: ProviderRoutingAnswersController
    let answerOverlayViewModel: AnswerOverlayViewModel
    let recordingTranscriptViewModel: RecordingTranscriptViewModel
    let historyViewModel: HistoryViewModel
    let settingsViewModel: SettingsViewModel
    let sessionStatusViewModel: SessionStatusViewModel
    let knowledgeBaseViewModel: KnowledgeBaseViewModel
    let navigationState = AppNavigationState()

    init(environment: AppEnvironment = .current()) {
        self.environment = environment
        let permissionsChecking = SystemPermissionsChecker()
        self.permissionsChecking = permissionsChecking
        preferredAudioSource = UserDefaultsPreferredAudioSourceStore(suiteName: environment.defaultsSuiteName)
        let settingsStore = AppSettingsStore(defaults: environment.defaults)
        self.settingsStore = settingsStore
        LocalizationCenter.shared.configure(with: settingsStore)

        answersSystemAudioCapturing = ScreenCaptureKitSystemAudioCapturing(outputFormat: .realtimeStreaming, permissions: permissionsChecking)
        transcribedAnswersSystemAudioCapturing = ScreenCaptureKitSystemAudioCapturing(outputFormat: .whisperTranscription, permissions: permissionsChecking)
        recordingSystemAudioCapturing = ScreenCaptureKitSystemAudioCapturing(outputFormat: .whisperTranscription, permissions: permissionsChecking)
        microphoneCapturing = AVEngineMicrophoneCapturing(permissions: permissionsChecking)

        let whisperKitTranscribing = WhisperKitTranscribing(modelID: settingsStore.whisperModelID)
        self.whisperKitTranscribing = whisperKitTranscribing
        localTranscribing = whisperKitTranscribing
        try? FileManager.default.createDirectory(at: environment.dataDirectory, withIntermediateDirectories: true)
        let databasePath = environment.dataDirectory.appendingPathComponent("meetingassistant.sqlite3").path
        meetingRepository = SQLiteMeetingRepository(path: databasePath)
        let questionAnswerRepository = SQLiteQuestionAnswerRepository(path: databasePath)
        self.questionAnswerRepository = questionAnswerRepository
        summaryRepository = SQLiteSummaryRepository(path: databasePath)
        let knowledgeNoteRepository = SQLiteKnowledgeNoteRepository(path: databasePath)
        self.knowledgeNoteRepository = knowledgeNoteRepository

        let legacyOpenAIStore = UserDefaultsSecretStore(defaults: environment.defaults)
        let openAIKeychain = KeychainSecretStore(service: ProviderKeychainServices.service(for: .openAIRealtime, namespace: environment.keychainNamespace))
        let anthropicKeychain = KeychainSecretStore(service: ProviderKeychainServices.service(for: .anthropicClaude, namespace: environment.keychainNamespace))
        let migrationOutcome = LegacyAPIKeyMigrator(legacy: legacyOpenAIStore, keychain: openAIKeychain).migrate()
        if migrationOutcome != .nothingToMigrate {
            settingsStore.lastKeyMigrationOutcome = String(describing: migrationOutcome)
        }
        let openAIStore = KeychainFirstSecretStore(primary: openAIKeychain, legacyFallback: legacyOpenAIStore)
        let anthropicStore = KeychainFirstSecretStore(primary: anthropicKeychain, legacyFallback: nil)
        secretStoring = openAIStore
        secretStores = [.openAIRealtime: openAIStore, .anthropicClaude: anthropicStore]

        summaryGenerating = OpenAIResponsesSummaryClient(
            secretStoring: openAIStore,
            meetingRepository: meetingRepository,
            modelID: settingsStore.summaryModelID
        )
        latencyRecording = InMemoryLatencyRecorder()
        let sessionTelemetry = SessionTelemetry()
        self.sessionTelemetry = sessionTelemetry
        let teeLatency = TelemetryLatencyRecorder(base: latencyRecording, telemetry: sessionTelemetry)
        manualAnswerTrigger = ManualAnswerTrigger()
        recordingsDirectory = environment.dataDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let meetingAudioRecording = WAVMeetingAudioFileWriter(baseDirectory: recordingsDirectory)

        let realtimeDiagLog = Self.makeRealtimeDiagLogger(directory: environment.dataDirectory)
        realtimeAnswering = OpenAIRealtimeAnswerClient(
            transport: URLSessionRealtimeWebSocketTransport(logger: realtimeDiagLog),
            credentialProviding: DirectKeyCredentialProvider(secretStoring: openAIStore),
            vadSettingsProvider: { [settingsStore] in
                var settings = settingsStore.vadSettings
                settings.automaticResponses = settingsStore.answerTriggerMode == .automatic
                return settings
            },
            sessionOptionsProvider: { [settingsStore] in settingsStore.realtimeSessionOptions() },
            latencyRecording: teeLatency,
            redactedLog: realtimeDiagLog
        )

        answersRingBuffer = AnswersRingBuffer()
        questionAnswerLogger = QuestionAnswerLogger(
            localTranscribing: localTranscribing,
            repository: questionAnswerRepository,
            modelID: settingsStore.whisperModelID
        )

        let answersController = AnswersModeController(
            systemAudio: answersSystemAudioCapturing,
            realtime: realtimeAnswering,
            answerTrigger: manualAnswerTrigger,
            preferredAudioSource: preferredAudioSource,
            instructionsProvider: { [settingsStore] in settingsStore.instructions(for: .realtimeAudio) },
            answersRingBuffer: answersRingBuffer,
            questionAnswerLogger: questionAnswerLogger,
            latencyRecording: teeLatency,
            telemetry: sessionTelemetry,
            modelIDProvider: { [settingsStore] in settingsStore.modelSelection(for: .openAIRealtime).modelID }
        )
        let claudeClient = AnthropicMessagesAnswerClient(apiKeyProvider: { [anthropicStore] in
            try anthropicStore.retrieveAPIKey()
        })
        let transcribedController = TranscribedAnswersModeController(
            systemAudio: transcribedAnswersSystemAudioCapturing,
            recognizer: WhisperKitFragmentRecognizer(transcriber: whisperKitTranscribing),
            generator: claudeClient,
            answerTrigger: manualAnswerTrigger,
            preferredAudioSource: preferredAudioSource,
            settingsProvider: { [settingsStore] in settingsStore.transcribedSessionSettings() },
            telemetry: sessionTelemetry,
            questionAnswerLogger: questionAnswerLogger,
            latencyRecording: teeLatency
        )
        let router = ProviderRoutingAnswersController(
            routes: [
                .openAIRealtime: .openAI(answersController),
                .anthropicClaude: .transcribed(transcribedController, preflight: { [anthropicStore] in
                    guard let key = try? anthropicStore.retrieveAPIKey(), !key.isEmpty else {
                        throw AnswerProviderError.missingAPIKey(.anthropicClaude)
                    }
                }),
            ],
            configurationProvider: { [settingsStore] in settingsStore.currentAnswerConfiguration() },
            spendPolicyProvider: { [settingsStore] in settingsStore.spendPolicy },
            prepare: { [settingsStore, knowledgeNoteRepository, questionAnswerRepository] in
                await Self.refreshLiveContext(settingsStore: settingsStore, notes: knowledgeNoteRepository, history: questionAnswerRepository)
            },
            telemetry: sessionTelemetry
        )
        let recordingController = RecordingModeController(
            systemAudio: recordingSystemAudioCapturing,
            microphone: microphoneCapturing,
            transcribing: localTranscribing,
            repository: meetingRepository,
            latencyRecording: latencyRecording,
            audioRecording: meetingAudioRecording,
            isAudioStorageEnabled: { [settingsStore] in settingsStore.audioStorageEnabled }
        )

        modeCoordinator = ModeCoordinator(
            controllers: [
                .answers: router,
                .recording: recordingController,
            ],
            latencyRecording: latencyRecording
        )

        modeViewModel = ModeSwitcherViewModel(modeCoordinator: modeCoordinator)
        answersModeController = answersController
        transcribedAnswersModeController = transcribedController
        answersRouter = router
        recordingModeController = recordingController
        answerOverlayViewModel = AnswerOverlayViewModel(
            modeCoordinator: modeCoordinator,
            answersController: router,
            manualAnswerTrigger: manualAnswerTrigger
        )
        recordingTranscriptViewModel = RecordingTranscriptViewModel(recordingController: recordingController)
        historyViewModel = HistoryViewModel(
            questionAnswerRepository: questionAnswerRepository,
            meetingRepository: meetingRepository,
            summaryGenerating: summaryGenerating,
            summaryRepository: summaryRepository
        )
        sessionStatusViewModel = SessionStatusViewModel(
            telemetry: sessionTelemetry,
            router: router,
            settingsStore: settingsStore
        )
        knowledgeBaseViewModel = KnowledgeBaseViewModel(
            repository: knowledgeNoteRepository,
            settingsStore: settingsStore,
            sessionStatus: sessionStatusViewModel
        )
        settingsViewModel = SettingsViewModel(
            settingsStore: settingsStore,
            secretStores: secretStores,
            preferredAudioSource: preferredAudioSource,
            permissionsChecking: permissionsChecking,
            recordingsDirectory: recordingsDirectory,
            modeViewModel: modeViewModel,
            sessionStatus: sessionStatusViewModel,
            overlayPreferences: OverlayPreferencesStore(defaults: environment.defaults)
        )

        let meetingRepository = self.meetingRepository
        Task {
            _ = try? await meetingRepository.reconcileInterruptedMeetings()
        }

        let desktopMeetingExporter = DesktopMeetingExporter(meetingRepository: meetingRepository, baseDirectory: environment.desktopExportDirectory)
        let recordingsDirectory = self.recordingsDirectory
        desktopExportTask = Task {
            for await meetingID in recordingController.finishedMeetings() {
                let audioDirectory = recordingsDirectory.appendingPathComponent(meetingID.rawValue.uuidString, isDirectory: true)
                await desktopMeetingExporter.export(meetingID: meetingID, audioSourceDirectory: audioDirectory)
            }
        }
    }

    nonisolated static func refreshLiveContext(
        settingsStore: AppSettingsStore,
        notes: any KnowledgeNoteRepository,
        history: any QuestionAnswerRepository
    ) async {
        let allNotes = (try? await notes.all()) ?? []
        settingsStore.liveContext.update(knowledge: KnowledgeContextBuilder.build(allNotes))
        let limit = settingsStore.answersMemoryCount
        let pairs = limit > 0 ? ((try? await history.history(limit: 50)) ?? []) : []
        settingsStore.liveContext.update(recentExchanges: RecentAnswersMemory.exchanges(from: pairs, limit: limit))
    }

    private static func makeRealtimeDiagLogger(directory: URL) -> @Sendable (String) -> Void {
        let url = directory.appendingPathComponent("realtime_diag.log")
        let lock = NSLock()
        return { message in
            lock.lock()
            defer { lock.unlock() }
            let line = "\(Date()) \(SecretRedactor.redact(message))\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
