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
    private let overlaySwitch: OverlaySwitch
    private let exportsDirectory: URL?
    private let companionService: CompanionService?
    private(set) var companionPort: UInt16?
    private(set) var companionStartFailed = false
    private(set) var companionURLs: [String] = []
    private(set) var companionDevices: [CompanionDeviceRow] = []
    private(set) var companionDevicesError = false
    private var applyingCompanionDirectly = false
    var companionPortText: String
    var companionLoopbackOnly: Bool {
        didSet {
            guard companionLoopbackOnly != oldValue else { return }
            settingsStore.companionLoopbackOnly = companionLoopbackOnly
            Task { await applyCompanionConfiguration() }
        }
    }
    private var companionURLTask: Task<Void, Never>?
    var companionServerEnabled: Bool {
        didSet {
            guard companionServerEnabled != oldValue else { return }
            settingsStore.companionServerEnabled = companionServerEnabled
            guard !applyingCompanionDirectly else { return }
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

    var overlayEnabled: Bool {
        get { overlaySwitch.isEnabled }
        set { overlaySwitch.setEnabled(newValue) }
    }

    var meetingAutoExportEnabled: Bool {
        get { settingsStore.meetingAutoExportEnabled }
        set { settingsStore.meetingAutoExportEnabled = newValue }
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
        companionService: CompanionService? = nil,
        overlaySwitch: OverlaySwitch? = nil,
        exportsDirectory: URL? = nil
    ) {
        self.companionService = companionService
        self.overlaySwitch = overlaySwitch ?? OverlaySwitch()
        self.exportsDirectory = exportsDirectory
        self.companionServerEnabled = settingsStore.companionServerEnabled
        self.companionPortText = String(settingsStore.companionPort)
        self.companionLoopbackOnly = settingsStore.companionLoopbackOnly
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
        await refreshCompanionURLs()
        await loadCompanionDevices()
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
        await refreshCompanionURLs()
    }

    func enableCompanionServer() async -> Bool {
        if !companionServerEnabled {
            applyingCompanionDirectly = true
            companionServerEnabled = true
            applyingCompanionDirectly = false
        }
        await applyCompanionServer(true)
        return companionPort != nil
    }

    var isCompanionPortValid: Bool {
        guard let value = Int(companionPortText.trimmingCharacters(in: .whitespaces)) else { return false }
        return (1024...65535).contains(value)
    }

    func commitCompanionPort() async {
        guard isCompanionPortValid, let value = UInt16(companionPortText.trimmingCharacters(in: .whitespaces)) else {
            companionPortText = String(settingsStore.companionPort)
            return
        }
        guard value != settingsStore.companionPort else { return }
        settingsStore.companionPort = value
        await applyCompanionConfiguration()
    }

    func applyCompanionConfiguration() async {
        guard let companionService else { return }
        do {
            if let port = try await companionService.update(configuration: settingsStore.companionConfiguration) {
                companionPort = port
            }
            companionStartFailed = false
        } catch {
            companionPort = nil
            companionStartFailed = true
        }
        await refreshCompanionURLs()
    }

    func loadCompanionDevices() async {
        guard let companionService else { return }
        do {
            let devices = try await companionService.pairingStore.pairedDevices()
            let connected = Set(await companionService.connectedDeviceIds())
            companionDevices = devices.map {
                CompanionDeviceRow(id: $0.deviceId, name: $0.name, createdAt: $0.createdAt, lastSeenAt: $0.lastSeenAt, isConnected: connected.contains($0.deviceId))
            }
            companionDevicesError = false
        } catch {
            companionDevicesError = true
        }
    }

    func revokeCompanionDevice(_ id: String) async {
        guard let companionService else { return }
        try? await companionService.pairingStore.revoke(deviceId: id)
        await loadCompanionDevices()
    }

    func revokeAllCompanionDevices() async {
        guard let companionService else { return }
        try? await companionService.pairingStore.revokeAll()
        await loadCompanionDevices()
    }

    func refreshCompanionURLs() async {
        guard let companionService, companionPort != nil else {
            companionURLTask?.cancel()
            companionURLTask = nil
            companionURLs = []
            return
        }
        companionURLs = await companionService.panelURLs()
        guard companionURLTask == nil else { return }
        let updates = companionService.panelURLUpdates()
        companionURLTask = Task { [weak self] in
            for await urls in updates {
                guard let self else { return }
                self.companionURLs = urls
            }
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

    func openExportsFolder() {
        guard let exportsDirectory else { return }
        try? FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(exportsDirectory)
    }

    func refreshPermissionStatuses() async {
        screenRecordingStatus = await permissionsChecking.status(for: .screenRecording)
        microphoneStatus = await permissionsChecking.status(for: .microphone)
    }
}

struct CompanionDeviceRow: Identifiable, Equatable {
    let id: String
    let name: String
    let createdAt: Date
    let lastSeenAt: Date?
    let isConnected: Bool
}
