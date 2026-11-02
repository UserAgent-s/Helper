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
final class APIKeyFieldState {
    let provider: AnswerProvider
    var input = ""
    private(set) var hasStoredKey = false
    private(set) var usesLegacyStorage = false
    private(set) var formatWarning = false
    private(set) var saveError: String?

    init(provider: AnswerProvider) {
        self.provider = provider
    }

    func refresh(using store: any SecretStoring) {
        let stored = (try? store.retrieveAPIKey()) ?? nil
        hasStoredKey = stored?.isEmpty == false
        usesLegacyStorage = (store as? KeychainFirstSecretStore)?.isUsingLegacyFallback ?? false
    }

    func save(using store: any SecretStoring) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard APIKeyFormatValidator.isPlausibleFormat(trimmed, for: provider) else {
            formatWarning = true
            return
        }
        formatWarning = false
        do {
            try store.store(apiKey: trimmed)
            saveError = nil
            input = ""
        } catch {
            saveError = loc("Не удалось сохранить в Keychain. Ключ не сохранён; повторите или проверьте доступ к связке ключей.")
        }
        refresh(using: store)
    }

    func delete(using store: any SecretStoring) {
        do {
            try store.deleteAPIKey()
            saveError = nil
        } catch {
            saveError = loc("Не удалось удалить ключ из Keychain.")
        }
        refresh(using: store)
    }
}

@MainActor
@Observable
final class SettingsViewModel {
    static let customModelTag = "__custom__"

    private let settingsStore: AppSettingsStore
    private let secretStores: [AnswerProvider: any SecretStoring]
    private let preferredAudioSource: any PreferredAudioSourceStoring
    private let permissionsChecking: any PermissionsChecking
    private let recordingsDirectory: URL
    private let overlayPreferences: OverlayPreferencesStore
    let modeViewModel: ModeSwitcherViewModel
    let sessionStatus: SessionStatusViewModel
    let remoteDisplay: RemoteDisplayCoordinator?

    let openAIKey = APIKeyFieldState(provider: .openAIRealtime)
    let anthropicKey = APIKeyFieldState(provider: .anthropicClaude)

    var preferredAudioSourceBundleID = ""
    private(set) var runningApplications: [(name: String, bundleID: String)] = []

    private(set) var screenRecordingStatus = PermissionStatus.notDetermined
    private(set) var microphoneStatus = PermissionStatus.notDetermined

    private(set) var providerChangeBlocked = false
    var customModelInput = ""
    private(set) var customModelError: String?
    private(set) var candidateProfile: CandidateProfile
    private(set) var revision = 0

    init(
        settingsStore: AppSettingsStore,
        secretStores: [AnswerProvider: any SecretStoring],
        preferredAudioSource: any PreferredAudioSourceStoring,
        permissionsChecking: any PermissionsChecking,
        recordingsDirectory: URL,
        modeViewModel: ModeSwitcherViewModel,
        sessionStatus: SessionStatusViewModel,
        overlayPreferences: OverlayPreferencesStore,
        remoteDisplay: RemoteDisplayCoordinator? = nil
    ) {
        self.remoteDisplay = remoteDisplay
        self.settingsStore = settingsStore
        self.secretStores = secretStores
        self.preferredAudioSource = preferredAudioSource
        self.permissionsChecking = permissionsChecking
        self.recordingsDirectory = recordingsDirectory
        self.modeViewModel = modeViewModel
        self.sessionStatus = sessionStatus
        self.overlayPreferences = overlayPreferences
        self.candidateProfile = settingsStore.candidateProfile
        runningApplications = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier, let name = app.localizedName else { return nil }
            return (name, bundleID)
        }.sorted { $0.name < $1.name }
    }

    var canChangeProviderOrModel: Bool {
        modeViewModel.currentMode == .passive
    }

    var answerProvider: AnswerProvider {
        get { _ = revision; return settingsStore.answerProvider }
        set {
            guard canChangeProviderOrModel else {
                providerChangeBlocked = true
                return
            }
            providerChangeBlocked = false
            settingsStore.answerProvider = newValue
            customPickerActive = false
            customModelError = nil
            customModelInput = currentSelection.isCustom ? currentSelection.modelID : ""
            settingsChanged()
        }
    }

    var currentSelection: AnswerModelSelection {
        _ = revision
        return settingsStore.modelSelection(for: settingsStore.answerProvider)
    }

    var availableModels: [AnswerModelDescriptor] {
        AnswerModelCatalog.models(for: answerProvider)
    }

    private(set) var customPickerActive = false

    var modelPickerTag: String {
        get { _ = revision; return (customPickerActive || currentSelection.isCustom) ? Self.customModelTag : currentSelection.modelID }
        set {
            guard canChangeProviderOrModel else {
                providerChangeBlocked = true
                return
            }
            providerChangeBlocked = false
            if newValue == Self.customModelTag {
                customPickerActive = true
                customModelInput = currentSelection.isCustom ? currentSelection.modelID : ""
                revision += 1
                return
            }
            customPickerActive = false
            settingsStore.setModelSelection(AnswerModelSelection(provider: answerProvider, modelID: newValue, isCustom: false))
            customModelError = nil
            settingsChanged()
        }
    }

    var isCustomModelSelected: Bool {
        _ = revision
        return customPickerActive || currentSelection.isCustom
    }

    func applyCustomModel() {
        guard canChangeProviderOrModel else {
            providerChangeBlocked = true
            return
        }
        let trimmed = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ModelIDValidator.isPlausible(trimmed) else {
            customModelError = loc("Некорректный идентификатор модели: допустимы латиница, цифры и - _ . : @, от 3 до 100 символов.")
            return
        }
        customModelError = nil
        let known = AnswerModelCatalog.descriptor(provider: answerProvider, modelID: trimmed) != nil
        settingsStore.setModelSelection(AnswerModelSelection(provider: answerProvider, modelID: trimmed, isCustom: !known))
        settingsChanged()
    }

    var selectedModelDescriptor: AnswerModelDescriptor? {
        AnswerModelCatalog.descriptor(provider: answerProvider, modelID: currentSelection.modelID)
    }

    var selectedModelPricingText: String {
        guard let pricing = selectedModelDescriptor?.pricing else {
            return loc("Тариф неизвестен — стоимость будет показана как «неизвестно».")
        }
        var text = String(format: "$%.2f / $%.2f ", pricing.textInputPerMillionUSD, pricing.textOutputPerMillionUSD) + loc("за 1M токенов текста (вход/выход)")
        if let audio = pricing.audioInputPerMillionUSD {
            text += String(format: ", $%.2f ", audio) + loc("за 1M аудио-токенов на вход")
        }
        text += ". " + loc("Источник:") + " \(pricing.sourceURL), " + loc("проверено") + " \(pricing.verifiedOn)."
        if let note = pricing.note ?? selectedModelDescriptor?.note { text += " \(note)." }
        return text
    }

    var answerTriggerMode: AnswerTriggerMode {
        get { _ = revision; return settingsStore.answerTriggerMode }
        set { settingsStore.answerTriggerMode = newValue; settingsChanged() }
    }

    var answerLength: AnswerLength {
        get { _ = revision; return settingsStore.answerLength }
        set { settingsStore.answerLength = newValue; settingsChanged() }
    }

    func updateProfile(_ keyPath: WritableKeyPath<CandidateProfile, String>, _ value: String) {
        candidateProfile[keyPath: keyPath] = value
        settingsStore.candidateProfile = candidateProfile
        settingsChanged()
    }

    func insertCaseTemplate() {
        let separator = candidateProfile.realCases.isEmpty ? "" : "\n\n"
        updateProfile(\.realCases, candidateProfile.realCases + separator + CandidateProfile.caseTemplate)
    }

    var answersMemoryCount: Int {
        get { _ = revision; return settingsStore.answersMemoryCount }
        set { settingsStore.answersMemoryCount = newValue; settingsChanged() }
    }

    var anthropicServerSideFallback: Bool {
        get { _ = revision; return settingsStore.anthropicServerSideFallback }
        set { settingsStore.anthropicServerSideFallback = newValue; settingsChanged() }
    }

    var spendLimitText: String {
        get { _ = revision; return settingsStore.spendLimitUSD.map { String(format: "%.2f", $0) } ?? "" }
        set {
            let normalized = newValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
            settingsStore.spendLimitUSD = Double(normalized)
            settingsChanged()
        }
    }

    var spendLimitMode: SpendLimitMode {
        get { _ = revision; return settingsStore.spendLimitMode }
        set { settingsStore.spendLimitMode = newValue; settingsChanged() }
    }

    var diagnosticsIncludeContent: Bool {
        get { _ = revision; return settingsStore.diagnosticsIncludeContentOptIn }
        set { settingsStore.diagnosticsIncludeContentOptIn = newValue; revision += 1 }
    }

    var keyMigrationNote: String? {
        guard let outcome = settingsStore.lastKeyMigrationOutcome else { return nil }
        if outcome.hasPrefix("failedKeptLegacy") {
            return loc("Перенос старого ключа OpenAI в Keychain не удался; ключ сохранён на прежнем месте и продолжает работать. Сохраните ключ заново, чтобы записать его в Keychain.")
        }
        if outcome == "conflictKeptBoth" {
            return loc("В Keychain уже есть другой ключ OpenAI; используется он. Старое значение из настроек не удалено.")
        }
        if outcome == "migrated" || outcome == "alreadyInKeychainLegacyRemoved" {
            return loc("Ключ OpenAI перенесён из настроек приложения в Keychain.")
        }
        return nil
    }

    var whisperModelID: String {
        get { settingsStore.whisperModelID }
        set { settingsStore.whisperModelID = newValue }
    }

    var summaryModelID: String {
        get { settingsStore.summaryModelID }
        set { settingsStore.summaryModelID = newValue }
    }

    var overlayStyle: OverlayStyle {
        get { overlayPreferences.style }
        set { overlayPreferences.style = newValue }
    }

    var overlayFontFamily: OverlayFontFamily {
        get { overlayPreferences.fontFamily }
        set { overlayPreferences.fontFamily = newValue }
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

    private func settingsChanged() {
        revision += 1
        sessionStatus.refreshPendingState()
    }

    func load() async {
        refreshAPIKeyStatus()
        candidateProfile = settingsStore.candidateProfile
        customModelInput = currentSelection.isCustom ? currentSelection.modelID : ""
        preferredAudioSourceBundleID = await preferredAudioSource.preferredApplicationBundleID() ?? ""
        screenRecordingStatus = await permissionsChecking.status(for: .screenRecording)
        microphoneStatus = await permissionsChecking.status(for: .microphone)
        await sessionStatus.refreshActiveConfiguration()
    }

    func refreshAPIKeyStatus() {
        if let store = secretStores[.openAIRealtime] { openAIKey.refresh(using: store) }
        if let store = secretStores[.anthropicClaude] { anthropicKey.refresh(using: store) }
    }

    func saveKey(_ field: APIKeyFieldState) {
        guard let store = secretStores[field.provider] else { return }
        field.save(using: store)
    }

    func deleteKey(_ field: APIKeyFieldState) {
        guard let store = secretStores[field.provider] else { return }
        field.delete(using: store)
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
