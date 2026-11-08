import AppKit
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
    private let preferredAudioSource: any PreferredAudioSourceStoring
    private let permissionsChecking: any PermissionsChecking
    private let recordingsDirectory: URL
    private let overlayPreferences = OverlayPreferencesStore()

    var apiKeyInput = ""
    private(set) var hasStoredAPIKey = false
    private(set) var hasAPIKeyFormatWarning = false

    var apiKeyStatusText: String {
        hasStoredAPIKey ? loc("сохранён") : loc("не задан")
    }

    var preferredAudioSourceBundleID = ""
    private(set) var runningApplications: [(name: String, bundleID: String)] = []

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

    var deviceRole: DeviceRole {
        get { settingsStore.deviceRole }
        set { settingsStore.deviceRole = newValue }
    }

    var historyRetentionDays: Int {
        get { settingsStore.historyRetentionDays ?? 0 }
        set { settingsStore.historyRetentionDays = newValue > 0 ? newValue : nil }
    }

    func selectChromeOnlyPreset() {
        preferredAudioSourceBundleID = SystemAudioScope.chromeOnlyPreset.targetApplicationBundleID ?? ""
        savePreferredAudioSource()
    }

    func selectWholeSystem() {
        preferredAudioSourceBundleID = ""
        savePreferredAudioSource()
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
        preferredAudioSource: any PreferredAudioSourceStoring,
        permissionsChecking: any PermissionsChecking,
        recordingsDirectory: URL
    ) {
        self.settingsStore = settingsStore
        self.secretStoring = secretStoring
        self.preferredAudioSource = preferredAudioSource
        self.permissionsChecking = permissionsChecking
        self.recordingsDirectory = recordingsDirectory
        runningApplications = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier, let name = app.localizedName else { return nil }
            return (name, bundleID)
        }.sorted { $0.name < $1.name }
    }

    func load() async {
        refreshAPIKeyStatus()
        preferredAudioSourceBundleID = await preferredAudioSource.preferredApplicationBundleID() ?? ""
        screenRecordingStatus = await permissionsChecking.status(for: .screenRecording)
        microphoneStatus = await permissionsChecking.status(for: .microphone)
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

    func savePreferredAudioSource() {
        let trimmed = preferredAudioSourceBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await preferredAudioSource.setPreferredApplicationBundleID(trimmed.isEmpty ? nil : trimmed) }
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
