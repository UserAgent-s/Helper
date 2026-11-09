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
    private var desktopExportTask: Task<Void, Never>?
    private var retentionSweepTask: Task<Void, Never>?
    let database: SQLiteDatabase

    let answersRingBuffer: AnswersRingBuffer
    let questionAnswerLogger: QuestionAnswerLogger

    let recordingModeController: RecordingModeController

    let modeViewModel: ModeSwitcherViewModel
    let answersModeController: AnswersModeController
    let answerOverlayViewModel: AnswerOverlayViewModel
    let recordingTranscriptViewModel: RecordingTranscriptViewModel
    let historyViewModel: HistoryViewModel
    let settingsViewModel: SettingsViewModel
    let navigationState = AppNavigationState()

    init() {
        let permissionsChecking = SystemPermissionsChecker()
        self.permissionsChecking = permissionsChecking
        preferredAudioSource = UserDefaultsPreferredAudioSourceStore()
        SettingsMigrator(defaults: .standard).migrateIfNeeded()
        let settingsStore = AppSettingsStore()
        self.settingsStore = settingsStore
        let profileKnowledge: any ProfileKnowledgeProviding = LegacyBackgroundProfileProvider { [settingsStore] in settingsStore.backgroundContext }
        LocalizationCenter.shared.configure(with: settingsStore)

        systemAudioCapturing = ScreenCaptureKitSystemAudioCapturing(outputFormat: .realtimeStreaming, permissions: permissionsChecking)
        let avMicrophone = AVEngineMicrophoneCapturing(permissions: permissionsChecking)
        microphoneCapturing = avMicrophone
        let audioDeviceCatalog = CoreAudioDeviceCatalog()
        self.audioDeviceCatalog = audioDeviceCatalog
        let preferredAudioSource = self.preferredAudioSource
        let captureHub = CaptureHub(
            system: systemAudioCapturing,
            microphone: avMicrophone,
            scope: { await preferredAudioSource.systemAudioScope() },
            microphonePlan: {
                MicrophoneDeviceResolver.plan(await preferredAudioSource.microphoneSelection(), catalog: audioDeviceCatalog)
            }
        )
        self.captureHub = captureHub
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

        let realtimeDiagLog = Self.makeRealtimeDiagLogger()
        realtimeAnswering = OpenAIRealtimeAnswerClient(
            transport: URLSessionRealtimeWebSocketTransport(logger: realtimeDiagLog),
            credentialProviding: DirectKeyCredentialProvider(secretStoring: secretStoring),
            vadSettingsProvider: { [settingsStore] in settingsStore.vadSettings },
            latencyRecording: latencyRecording,
            redactedLog: realtimeDiagLog
        )

        answersRingBuffer = AnswersRingBuffer()
        questionAnswerLogger = QuestionAnswerLogger(
            localTranscribing: localTranscribing,
            repository: questionAnswerRepository,
            answerModelID: OpenAIRealtimeAnswerClient.modelID,
            questionTranscriptionModelID: { [settingsStore] in settingsStore.whisperModelID }
        )

        let answersController = AnswersModeController(
            captureHub: captureHub,
            realtime: realtimeAnswering,
            answerTrigger: manualAnswerTrigger,
            instructionsProvider: { [profileKnowledge] in
                RealtimeInstructions.system(for: settingsStore.answerLength, background: await profileKnowledge.realtimeDigest())
            },
            answersRingBuffer: answersRingBuffer,
            questionAnswerLogger: questionAnswerLogger,
            latencyRecording: latencyRecording
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

        modeViewModel = ModeSwitcherViewModel(modeCoordinator: modeCoordinator, captureNotices: captureHub.notices.subscribe("modeSwitcher"))
        answersModeController = answersController
        recordingModeController = recordingController
        answerOverlayViewModel = AnswerOverlayViewModel(
            modeCoordinator: modeCoordinator,
            answersController: answersController,
            manualAnswerTrigger: manualAnswerTrigger
        )
        recordingTranscriptViewModel = RecordingTranscriptViewModel(recordingController: recordingController)
        historyViewModel = HistoryViewModel(
            questionAnswerRepository: questionAnswerRepository,
            meetingRepository: meetingRepository,
            summaryGenerating: summaryGenerating,
            summaryRepository: summaryRepository
        )
        settingsViewModel = SettingsViewModel(
            settingsStore: settingsStore,
            secretStoring: secretStoring,
            preferredAudioSource: preferredAudioSource,
            permissionsChecking: permissionsChecking,
            recordingsDirectory: recordingsDirectory,
            audioDeviceCatalog: audioDeviceCatalog
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

        let desktopMeetingExporter = DesktopMeetingExporter(meetingRepository: meetingRepository, baseDirectory: Self.desktopDirectoryURL())
        let recordingsDirectory = self.recordingsDirectory
        desktopExportTask = Task {
            for await meetingID in recordingController.finishedMeetings() {
                let audioDirectory = recordingsDirectory.appendingPathComponent(meetingID.rawValue.uuidString, isDirectory: true)
                await desktopMeetingExporter.export(meetingID: meetingID, audioSourceDirectory: audioDirectory)
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

    private static func desktopDirectoryURL() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    private static func makeRealtimeDiagLogger() -> @Sendable (String) -> Void {
        let path = "/tmp/ma_realtime_diag.log"
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
