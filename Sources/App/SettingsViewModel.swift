import AppKit
import CompanionBridge
import Domain
import Foundation
import Observation
import RealtimeClient
import SecurityStore
import Summary
import Transcription

@MainActor
@Observable
final class SettingsViewModel {
    private let settingsStore: AppSettingsStore
    private let secretStoring: any SecretStoring
    private let permissionsChecking: any PermissionsChecking
    private let recordingsDirectory: URL
    private let overlayPreferences = OverlayPreferencesStore()
    private let companionService: CompanionService?
    private(set) var companionPort: UInt16?
    private(set) var companionStartFailed = false
    var companionServerEnabled: Bool {
        didSet {
            guard companionServerEnabled != oldValue else { return }
            settingsStore.companionServerEnabled = companionServerEnabled
            let enabled = companionServerEnabled
            Task { await applyCompanionServer(enabled) }
        }
    }

    var apiKeyInput = ""
    private(set) var hasStoredAPIKey = false
    private(set) var hasAPIKeyFormatWarning = false

    var apiKeyStatusText: String {
        hasStoredAPIKey ? loc("сохранён") : loc("не задан")
    }

    let audio: AudioSettingsViewModel

    private(set) var screenRecordingStatus = PermissionStatus.notDetermined
    private(set) var microphoneStatus = PermissionStatus.notDetermined

    var whisperModelID: String {
        get { settingsStore.whisperModelID }
        set { settingsStore.whisperModelID = newValue }
    }

    var summaryModelID: String {
        get { settingsStore.summaryModelID }
        set { settingsStore.summaryModelID = newValue }
    }

    var answerLength: AnswerLength {
        get { settingsStore.answerLength }
        set { settingsStore.answerLength = newValue }
    }

    var backgroundContext: String {
        get { settingsStore.backgroundContext }
        set { settingsStore.backgroundContext = newValue }
    }

    var overlayStyle: OverlayStyle {
        get { overlayPreferences.style }
        set { overlayPreferences.style = newValue }
    }

    var overlayFontFamily: OverlayFontFamily {
        get { overlayPreferences.fontFamily }
        set { overlayPreferences.fontFamily = newValue }
    }

    var systemAudioBackend: SystemAudioBackend {
        get { settingsStore.systemAudioBackend }
        set { settingsStore.systemAudioBackend = newValue }
    }

    var deviceRole: DeviceRole {
        get { settingsStore.deviceRole }
        set { settingsStore.deviceRole = newValue }
    }

    var historyRetentionDays: Int {
        get { settingsStore.historyRetentionDays ?? 0 }
        set { settingsStore.historyRetentionDays = newValue > 0 ? newValue : nil }
    }

    var diagnosticsIncludeContentOptIn: Bool {
        get { settingsStore.diagnosticsIncludeContentOptIn }
        set { settingsStore.diagnosticsIncludeContentOptIn = newValue }
    }

    var audioStorageEnabled: Bool {
        get { settingsStore.audioStorageEnabled }
        set { settingsStore.audioStorageEnabled = newValue }
    }

    var vadThreshold: Double {
        get { settingsStore.vadSettings.threshold }
        set { settingsStore.vadSettings = RealtimeVADSettings(threshold: newValue, prefixPaddingMs: vadPrefixPaddingMs, silenceDurationMs: vadSilenceDurationMs) }
    }

    var vadPrefixPaddingMs: Int {
        get { settingsStore.vadSettings.prefixPaddingMs }
        set { settingsStore.vadSettings = RealtimeVADSettings(threshold: vadThreshold, prefixPaddingMs: newValue, silenceDurationMs: vadSilenceDurationMs) }
    }

    var vadSilenceDurationMs: Int {
        get { settingsStore.vadSettings.silenceDurationMs }
        set { settingsStore.vadSettings = RealtimeVADSettings(threshold: vadThreshold, prefixPaddingMs: vadPrefixPaddingMs, silenceDurationMs: newValue) }
    }

    init(
        settingsStore: AppSettingsStore,
        secretStoring: any SecretStoring,
        audio: AudioSettingsViewModel,
        permissionsChecking: any PermissionsChecking,
        recordingsDirectory: URL,
        companionService: CompanionService? = nil
    ) {
        self.companionService = companionService
        self.companionServerEnabled = settingsStore.companionServerEnabled
        self.audio = audio
        self.settingsStore = settingsStore
        self.secretStoring = secretStoring
        self.permissionsChecking = permissionsChecking
        self.recordingsDirectory = recordingsDirectory
    }

    func load() async {
        refreshAPIKeyStatus()
        await audio.load()
        companionPort = await companionService?.port
        screenRecordingStatus = await permissionsChecking.status(for: .screenRecording)
        microphoneStatus = await permissionsChecking.status(for: .microphone)
    }

    func applyCompanionServer(_ enabled: Bool) async {
        guard let companionService else { return }
        if enabled {
            do {
                companionPort = try await companionService.start()
                companionStartFailed = false
            } catch {
                companionPort = nil
                companionStartFailed = true
            }
        } else {
            await companionService.stop()
            companionPort = nil
            companionStartFailed = false
        }
    }

    func refreshAPIKeyStatus() {
        let stored = (try? secretStoring.retrieveAPIKey()) ?? nil
        hasStoredAPIKey = stored?.isEmpty == false
    }

    func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard APIKeyFormatValidator.isPlausibleFormat(trimmed) else {
            hasAPIKeyFormatWarning = true
            return
        }
        hasAPIKeyFormatWarning = false
        try? secretStoring.store(apiKey: trimmed)
        apiKeyInput = ""
        refreshAPIKeyStatus()
    }

    func deleteAPIKey() {
        try? secretStoring.deleteAPIKey()
        refreshAPIKeyStatus()
    }

    func requestScreenRecordingAccess() {
        Task {
            screenRecordingStatus = await permissionsChecking.request(.screenRecording)
        }
    }

    func requestMicrophoneAccess() {
        Task {
            microphoneStatus = await permissionsChecking.request(.microphone)
        }
    }

    func openScreenRecordingSystemSettings() {
        SystemSettingsLinks.openScreenRecordingSettings()
    }

    func openMicrophoneSystemSettings() {
        SystemSettingsLinks.openMicrophoneSettings()
    }

    func openRecordingsFolder() {
        NSWorkspace.shared.open(recordingsDirectory)
    }

    func refreshPermissionStatuses() async {
        screenRecordingStatus = await permissionsChecking.status(for: .screenRecording)
        microphoneStatus = await permissionsChecking.status(for: .microphone)
    }
}
