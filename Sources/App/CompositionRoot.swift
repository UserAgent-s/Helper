import Foundation
import Domain
import AudioCapture
import RealtimeClient
import Transcription
import Persistence
import SecurityStore
import Diagnostics
import Summary
import OverlayReducer
import CompanionProtocol
import CompanionBridge

@MainActor
final class CompositionRoot {
    let modeCoordinator: ModeCoordinator
    let manualAnswerTrigger: ManualAnswerTrigger
    let preferredAudioSource: any PreferredAudioSourceStoring
    let permissionsChecking: any PermissionsChecking

    let systemAudioCapturing: any SystemAudioCapturing
    let microphoneCapturing: any MicrophoneCapturing
    let captureHub: CaptureHub
    let audioDeviceCatalog: CoreAudioDeviceCatalog
    let outputRoutes = AsyncBroadcaster<OutputRoute>(replayLatest: true, initial: .unknown)
    let outputRouteMonitor: OutputRouteMonitor
    private var outputRouteLifecycleTask: Task<Void, Never>?
    private var deviceChangeTasks: [Task<Void, Never>] = []
    let realtimeAnswering: any LiveResponder
    let localTranscribing: any LocalTranscribing
    let whisperKitTranscribing: WhisperKitTranscribing
    let meetingRepository: any MeetingRepository
    let questionAnswerRepository: any QuestionAnswerRepository
    let summaryRepository: any SummaryRepository
    let summaryGenerating: any SummaryGenerating
    let secretStoring: any SecretStoring
    let latencyRecording: InMemoryLatencyRecorder
    let settingsStore: AppSettingsStore
    let recordingsDirectory: URL
    private var meetingExportTask: Task<Void, Never>?
    private var retentionSweepTask: Task<Void, Never>?
    let database: SQLiteDatabase

    let questionAnswerLogger: QuestionAnswerLogger

    let recordingModeController: RecordingModeController

    let modeViewModel: ModeSwitcherViewModel
    let answersModeController: AnswersModeController
    let answerOverlayViewModel: AnswerOverlayViewModel
    let recordingTranscriptViewModel: RecordingTranscriptViewModel
    let historyViewModel: HistoryViewModel
    let settingsViewModel: SettingsViewModel
    let navigationState = AppNavigationState()
    let companionBridge: CompanionBridge
    let companionService: CompanionService
    let modeActivityGuard = ModeActivityGuard()
    let overlaySwitch = OverlaySwitch()
    let exportsDirectory: URL
    let companionPairingViewModel: CompanionPairingViewModel

    init() {
        let permissionsChecking = SystemPermissionsChecker()
        self.permissionsChecking = permissionsChecking
        preferredAudioSource = UserDefaultsPreferredAudioSourceStore()
        SettingsMigrator(defaults: .standard).migrateIfNeeded()
        let settingsStore = AppSettingsStore()
        self.settingsStore = settingsStore
        let profileKnowledge: any ProfileKnowledgeProviding = LegacyBackgroundProfileProvider { [settingsStore] in settingsStore.backgroundContext }
        LocalizationCenter.shared.configure(with: settingsStore)

        let avMicrophone = AVEngineMicrophoneCapturing(permissions: permissionsChecking)
        microphoneCapturing = avMicrophone
        let audioDeviceCatalog = CoreAudioDeviceCatalog()
        self.audioDeviceCatalog = audioDeviceCatalog
        if settingsStore.systemAudioBackend == .coreAudioTap, #available(macOS 14.2, *) {
            systemAudioCapturing = CoreAudioTapSystemAudioCapturing(catalog: audioDeviceCatalog)
        } else {
            systemAudioCapturing = ScreenCaptureKitSystemAudioCapturing(outputFormat: .realtimeStreaming, permissions: permissionsChecking)
        }
        let preferredAudioSource = self.preferredAudioSource
        let captureHub = CaptureHub(
            system: systemAudioCapturing,
            microphone: avMicrophone,
            scope: { await preferredAudioSource.systemAudioScope() },
            microphonePlan: { [settingsStore] profile in
                MicrophoneDeviceResolver.plan(
                    await preferredAudioSource.microphoneSelection(),
                    catalog: audioDeviceCatalog,
                    profile: profile,
                    routePolicy: settingsStore.outputRoutePolicy
                )
            }
        )
        self.captureHub = captureHub
        outputRouteMonitor = OutputRouteMonitor(catalog: audioDeviceCatalog, routes: outputRoutes, notices: captureHub.notices)
        deviceChangeTasks = [audioDeviceCatalog.changes(), avMicrophone.engineReconfigurations()].map { changes in
            Task {
                for await change in changes {
                    await captureHub.handleDeviceChange(change)
                }
            }
        }

        let whisperKitTranscribing = WhisperKitTranscribing(modelID: settingsStore.whisperModelID)
        self.whisperKitTranscribing = whisperKitTranscribing
        localTranscribing = whisperKitTranscribing
        let databasePath = Self.databaseFilePath()
        let database = SQLiteDatabase(path: databasePath)
        self.database = database
        meetingRepository = SQLiteMeetingRepository(database: database)
        questionAnswerRepository = SQLiteQuestionAnswerRepository(database: database)
        summaryRepository = SQLiteSummaryRepository(database: database)
        secretStoring = UserDefaultsSecretStore()
        summaryGenerating = OpenAIResponsesSummaryClient(
            secretStoring: secretStoring,
            meetingRepository: meetingRepository,
            modelID: settingsStore.summaryModelID
        )
        latencyRecording = InMemoryLatencyRecorder()
        manualAnswerTrigger = ManualAnswerTrigger()
        recordingsDirectory = Self.recordingsDirectoryURL()
        let meetingAudioRecording = WAVMeetingAudioFileWriter(baseDirectory: recordingsDirectory)

        let realtimeDiagLog = Self.makeRealtimeDiagLogger(
            url: AppFileLocations.realtimeDiagnosticsLog(library: AppFileLocations.userDirectory(.libraryDirectory))
        )
        realtimeAnswering = OpenAIRealtimeAnswerClient(
            transport: URLSessionRealtimeWebSocketTransport(logger: realtimeDiagLog),
            credentialProviding: DirectKeyCredentialProvider(secretStoring: secretStoring),
            vadSettingsProvider: { [settingsStore] in settingsStore.vadSettings },
            latencyRecording: latencyRecording,
            redactedLog: realtimeDiagLog
        )

        questionAnswerLogger = QuestionAnswerLogger(
            repository: questionAnswerRepository,
            answerModelID: OpenAIRealtimeAnswerClient.modelID,
            questionTranscriptionModelID: { OpenAIRealtimeAnswerClient.transcriptionModelID }
        )

        let meTranscription = OpenAIRealtimeTranscriptionClient(
            transport: URLSessionRealtimeWebSocketTransport(logger: realtimeDiagLog),
            credentialProviding: DirectKeyCredentialProvider(secretStoring: secretStoring),
            redactedLog: realtimeDiagLog
        )
        let meChannel = MeTranscriptionSink(
            captureHub: captureHub,
            transcriber: meTranscription,
            responder: realtimeAnswering,
            redactedLog: realtimeDiagLog
        )
        let answersController = AnswersModeController(
            captureHub: captureHub,
            realtime: realtimeAnswering,
            answerTrigger: manualAnswerTrigger,
            instructionsProvider: { [profileKnowledge] in
                RealtimeInstructions.system(for: settingsStore.answerLength, background: await profileKnowledge.realtimeDigest())
            },
            questionAnswerLogger: questionAnswerLogger,
            latencyRecording: latencyRecording,
            meChannel: meChannel,
            isMeChannelEnabled: { [settingsStore] in settingsStore.meChannelEnabled }
        )
        let recordingController = RecordingModeController(
            captureHub: captureHub,
            transcriptionFormat: WhisperFrameConverter(),
            transcribing: localTranscribing,
            repository: meetingRepository,
            latencyRecording: latencyRecording,
            audioRecording: meetingAudioRecording,
            isAudioStorageEnabled: { [settingsStore] in settingsStore.audioStorageEnabled }
        )

        modeCoordinator = ModeCoordinator(
            controllers: [
                .answers: answersController,
                .recording: recordingController,
            ],
            latencyRecording: latencyRecording
        )

        modeViewModel = ModeSwitcherViewModel(
            modeCoordinator: modeCoordinator,
            captureNotices: captureHub.notices.subscribe("modeSwitcher"),
            outputRoutes: outputRoutes.subscribe("modeSwitcher"),
            outputRoutePolicy: { [settingsStore] in settingsStore.outputRoutePolicy }
        )
        let outputRouteMonitor = self.outputRouteMonitor
        let modeStates = modeCoordinator.stateUpdates(subscriber: "outputRouteMonitor")
        outputRouteLifecycleTask = Task {
            for await state in modeStates {
                if state.mode == .passive {
                    await outputRouteMonitor.stop()
                } else {
                    await outputRouteMonitor.start()
                }
            }
        }
        answersModeController = answersController
        recordingModeController = recordingController
        answerOverlayViewModel = AnswerOverlayViewModel(
            modeCoordinator: modeCoordinator,
            answersController: answersController,
            manualAnswerTrigger: manualAnswerTrigger
        )
        recordingTranscriptViewModel = RecordingTranscriptViewModel(recordingController: recordingController)
        let companionBridge = CompanionBridge(
            control: LiveCompanionDomain(modeCoordinator: modeCoordinator, answers: answersController, trigger: manualAnswerTrigger)
        )
        let companionFeeds = LiveCompanionDomain.feeds(modeCoordinator: modeCoordinator, answers: answersController, captureHub: captureHub)
        let companionService = CompanionService(
            pairing: PairingStore(storage: SQLitePairedDeviceStore(database: database)),
            bridge: companionBridge,
            configuration: settingsStore.companionConfiguration,
            serverVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        )
        self.companionBridge = companionBridge
        self.companionService = companionService
        let sleepStates = modeCoordinator.stateUpdates(subscriber: "modeActivityGuard")
        let modeActivityGuard = self.modeActivityGuard
        Task { await modeActivityGuard.start(states: sleepStates) }
        let overlayEnabled = overlaySwitch.isEnabled
        overlaySwitch.observe { enabled in
            Task { await companionBridge.setOverlayEnabled(enabled) }
        }
        Task {
            await companionBridge.setOverlayEnabled(overlayEnabled)
            await companionBridge.start(feeds: companionFeeds)
            if settingsStore.companionServerEnabled {
                _ = try? await companionService.start()
            }
        }
        historyViewModel = HistoryViewModel(
            questionAnswerRepository: questionAnswerRepository,
            meetingRepository: meetingRepository,
            summaryGenerating: summaryGenerating,
            summaryRepository: summaryRepository
        )
        let exportsDirectory = AppFileLocations.exportsDirectory(documents: AppFileLocations.userDirectory(.documentDirectory))
        self.exportsDirectory = exportsDirectory
        let settingsViewModel = SettingsViewModel(
            settingsStore: settingsStore,
            secretStoring: secretStoring,
            audio: AudioSettingsViewModel(
                store: preferredAudioSource,
                catalog: audioDeviceCatalog,
                settingsStore: settingsStore,
                levels: captureHub.levels.subscribe("audioSettings", policy: .bufferingNewest(8)),
                onMicrophonePlanChanged: { Task { await captureHub.refreshMicrophonePlan() } }
            ),
            permissionsChecking: permissionsChecking,
            recordingsDirectory: recordingsDirectory,
            companionService: companionService,
            overlaySwitch: overlaySwitch,
            exportsDirectory: exportsDirectory
        )
        self.settingsViewModel = settingsViewModel
        companionPairingViewModel = CompanionPairingViewModel(
            service: companionService,
            enableServer: { await settingsViewModel.enableCompanionServer() }
        )

        let meetingRepository = self.meetingRepository
        let retentionSweeper = RetentionSweeper(database: database, recordingsDirectory: recordingsDirectory)
        retentionSweepTask = Task { [settingsStore] in
            _ = try? await meetingRepository.reconcileInterruptedMeetings()
            while !Task.isCancelled {
                _ = try? await retentionSweeper.sweep(retentionDays: settingsStore.historyRetentionDays)
                try? await Task.sleep(for: .seconds(86_400))
            }
        }

        let autoExporter = MeetingAutoExporter(
            isEnabled: { [settingsStore] in settingsStore.meetingAutoExportEnabled },
            exporter: MeetingFolderExporter(meetingRepository: meetingRepository, baseDirectory: exportsDirectory),
            recordingsDirectory: recordingsDirectory
        )
        meetingExportTask = Task {
            for await meetingID in recordingController.finishedMeetings() {
                await autoExporter.meetingFinished(meetingID)
            }
        }
    }

    private static func databaseFilePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let directory = appSupport?.appendingPathComponent("UserAgent057", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory?.appendingPathComponent("useragent057.sqlite3").path ?? ":memory:"
    }

    private static func recordingsDirectoryURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let base = appSupport ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("UserAgent057", isDirectory: true).appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func makeRealtimeDiagLogger(url: URL) -> @Sendable (String) -> Void {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path
        let lock = NSLock()
        return { message in
            lock.lock()
            defer { lock.unlock() }
            let line = "\(Date()) \(message)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }
}
