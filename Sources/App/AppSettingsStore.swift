import Foundation
import Domain
import RealtimeClient
import Transcription
import Summary

final class AppSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    let liveContext = LiveAnswerContext()

    private enum Keys {
        static let whisperModelID = "com.local.MeetingAssistant.settings.whisperModelID"
        static let summaryModelID = "com.local.MeetingAssistant.settings.summaryModelID"
        static let audioStorageEnabled = "com.local.MeetingAssistant.settings.audioStorageEnabled"
        static let historyRetentionDays = "com.local.MeetingAssistant.settings.historyRetentionDays"
        static let vadThreshold = "com.local.MeetingAssistant.settings.vadThreshold"
        static let vadPrefixPaddingMs = "com.local.MeetingAssistant.settings.vadPrefixPaddingMs"
        static let vadSilenceDurationMs = "com.local.MeetingAssistant.settings.vadSilenceDurationMs"
        static let onboardingCompleted = "com.local.MeetingAssistant.settings.onboardingCompleted"
        static let diagnosticsIncludeAudioStorageState = "com.local.MeetingAssistant.settings.diagnosticsOptIn"
        static let appLanguage = "com.local.MeetingAssistant.settings.appLanguage"
        static let answerLength = "com.local.MeetingAssistant.settings.answerLength"
        static let backgroundContext = "com.local.MeetingAssistant.settings.backgroundContext"
        static let answerProvider = "com.local.MeetingAssistant.settings.answerProvider"
        static let openAIModelID = "com.local.MeetingAssistant.settings.openAIModelID"
        static let openAIModelIsCustom = "com.local.MeetingAssistant.settings.openAIModelIsCustom"
        static let anthropicModelID = "com.local.MeetingAssistant.settings.anthropicModelID"
        static let anthropicModelIsCustom = "com.local.MeetingAssistant.settings.anthropicModelIsCustom"
        static let answerTriggerMode = "com.local.MeetingAssistant.settings.answerTriggerMode"
        static let answerProfile = "com.local.MeetingAssistant.settings.answerProfile"
        static let candidateProfile = "com.local.MeetingAssistant.settings.candidateProfile"
        static let spendLimitUSD = "com.local.MeetingAssistant.settings.spendLimitUSD"
        static let spendLimitMode = "com.local.MeetingAssistant.settings.spendLimitMode"
        static let anthropicServerSideFallback = "com.local.MeetingAssistant.settings.anthropicServerSideFallback"
        static let lastKeyMigrationOutcome = "com.local.MeetingAssistant.settings.lastKeyMigrationOutcome"
        static let answersMemoryCount = "com.local.MeetingAssistant.settings.answersMemoryCount"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var whisperModelID: String {
        get { defaults.string(forKey: Keys.whisperModelID) ?? WhisperModelCatalog.defaultModelID }
        set { defaults.set(newValue, forKey: Keys.whisperModelID) }
    }

    var summaryModelID: String {
        get { defaults.string(forKey: Keys.summaryModelID) ?? SummaryModelCatalog.defaultModelID }
        set { defaults.set(newValue, forKey: Keys.summaryModelID) }
    }

    var audioStorageEnabled: Bool {
        get { defaults.bool(forKey: Keys.audioStorageEnabled) }
        set { defaults.set(newValue, forKey: Keys.audioStorageEnabled) }
    }

    var historyRetentionDays: Int? {
        get { defaults.object(forKey: Keys.historyRetentionDays) as? Int }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Keys.historyRetentionDays)
                return
            }
            defaults.set(newValue, forKey: Keys.historyRetentionDays)
        }
    }

    var vadSettings: RealtimeVADSettings {
        get {
            RealtimeVADSettings(
                threshold: defaults.object(forKey: Keys.vadThreshold) as? Double ?? RealtimeVADSettings.safeDefault.threshold,
                prefixPaddingMs: defaults.object(forKey: Keys.vadPrefixPaddingMs) as? Int ?? RealtimeVADSettings.safeDefault.prefixPaddingMs,
                silenceDurationMs: defaults.object(forKey: Keys.vadSilenceDurationMs) as? Int ?? RealtimeVADSettings.safeDefault.silenceDurationMs
            )
        }
        set {
            defaults.set(newValue.threshold, forKey: Keys.vadThreshold)
            defaults.set(newValue.prefixPaddingMs, forKey: Keys.vadPrefixPaddingMs)
            defaults.set(newValue.silenceDurationMs, forKey: Keys.vadSilenceDurationMs)
        }
    }

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Keys.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Keys.onboardingCompleted) }
    }

    var diagnosticsIncludeContentOptIn: Bool {
        get { defaults.bool(forKey: Keys.diagnosticsIncludeAudioStorageState) }
        set { defaults.set(newValue, forKey: Keys.diagnosticsIncludeAudioStorageState) }
    }

    var appLanguage: AppLanguage {
        get { AppLanguage(rawValue: defaults.string(forKey: Keys.appLanguage) ?? "") ?? .ru }
        set { defaults.set(newValue.rawValue, forKey: Keys.appLanguage) }
    }

    var answerLength: AnswerLength {
        get { AnswerLength(rawValue: defaults.string(forKey: Keys.answerLength) ?? "") ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: Keys.answerLength) }
    }

    var backgroundContext: String {
        get { defaults.string(forKey: Keys.backgroundContext) ?? "" }
        set { defaults.set(newValue, forKey: Keys.backgroundContext) }
    }

    var answerProvider: AnswerProvider {
        get { AnswerProvider(rawValue: defaults.string(forKey: Keys.answerProvider) ?? "") ?? .openAIRealtime }
        set { defaults.set(newValue.rawValue, forKey: Keys.answerProvider) }
    }

    func modelSelection(for provider: AnswerProvider) -> AnswerModelSelection {
        let (idKey, customKey) = Self.modelKeys(for: provider)
        let stored = defaults.string(forKey: idKey)
        let isCustom = defaults.bool(forKey: customKey)
        guard let stored, ModelIDValidator.isPlausible(stored) else {
            return AnswerModelSelection(provider: provider, modelID: AnswerModelCatalog.defaultModelID(for: provider), isCustom: false)
        }
        let known = AnswerModelCatalog.descriptor(provider: provider, modelID: stored) != nil
        return AnswerModelSelection(provider: provider, modelID: stored, isCustom: isCustom || !known)
    }

    func setModelSelection(_ selection: AnswerModelSelection) {
        let (idKey, customKey) = Self.modelKeys(for: selection.provider)
        defaults.set(selection.modelID, forKey: idKey)
        defaults.set(selection.isCustom, forKey: customKey)
    }

    private static func modelKeys(for provider: AnswerProvider) -> (String, String) {
        switch provider {
        case .openAIRealtime: (Keys.openAIModelID, Keys.openAIModelIsCustom)
        case .anthropicClaude: (Keys.anthropicModelID, Keys.anthropicModelIsCustom)
        }
    }

    var answerTriggerMode: AnswerTriggerMode {
        get { AnswerTriggerMode(rawValue: defaults.string(forKey: Keys.answerTriggerMode) ?? "") ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: Keys.answerTriggerMode) }
    }

    var answerProfile: InterviewAnswerProfile {
        get { InterviewAnswerProfile(rawValue: defaults.string(forKey: Keys.answerProfile) ?? "") ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: Keys.answerProfile) }
    }

    var candidateProfile: CandidateProfile {
        get {
            if let data = defaults.data(forKey: Keys.candidateProfile),
               let profile = try? JSONDecoder().decode(CandidateProfile.self, from: data) {
                return profile
            }
            return CandidateProfile.migratedFromLegacyBackground(backgroundContext)
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.candidateProfile)
        }
    }

    var spendLimitUSD: Double? {
        get {
            guard let value = defaults.object(forKey: Keys.spendLimitUSD) as? Double, value > 0 else { return nil }
            return value
        }
        set {
            if let newValue, newValue > 0 {
                defaults.set(newValue, forKey: Keys.spendLimitUSD)
            } else {
                defaults.removeObject(forKey: Keys.spendLimitUSD)
            }
        }
    }

    var spendLimitMode: SpendLimitMode {
        get { SpendLimitMode(rawValue: defaults.string(forKey: Keys.spendLimitMode) ?? "") ?? .warnOnly }
        set { defaults.set(newValue.rawValue, forKey: Keys.spendLimitMode) }
    }

    var spendPolicy: SpendPolicy {
        SpendPolicy(limitUSD: spendLimitUSD, mode: spendLimitMode)
    }

    var anthropicServerSideFallback: Bool {
        get { defaults.object(forKey: Keys.anthropicServerSideFallback) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.anthropicServerSideFallback) }
    }

    var lastKeyMigrationOutcome: String? {
        get { defaults.string(forKey: Keys.lastKeyMigrationOutcome) }
        set { defaults.set(newValue, forKey: Keys.lastKeyMigrationOutcome) }
    }

    var answersMemoryCount: Int {
        get { min(10, max(0, defaults.object(forKey: Keys.answersMemoryCount) as? Int ?? 5)) }
        set { defaults.set(min(10, max(0, newValue)), forKey: Keys.answersMemoryCount) }
    }

    func currentAnswerConfiguration() -> AnswerSessionConfiguration {
        let provider = answerProvider
        return AnswerSessionConfiguration(
            selection: modelSelection(for: provider),
            triggerMode: answerTriggerMode,
            answerLength: answerLength,
            answerProfile: answerProfile,
            profileFingerprint: candidateProfile.fingerprint + "-" + liveContext.fingerprint
        )
    }

    func instructions(for adaptation: InstructionsAdaptation) -> String {
        AnswerInstructionsBuilder.build(
            adaptation: adaptation,
            length: answerLength,
            answerProfile: answerProfile,
            candidate: candidateProfile,
            knowledge: liveContext.knowledgeContext,
            recentExchanges: liveContext.recentExchanges
        )
    }

    func realtimeSessionOptions() -> RealtimeSessionOptions {
        let selection = modelSelection(for: .openAIRealtime)
        let supportsReasoning = AnswerModelCatalog.descriptor(provider: .openAIRealtime, modelID: selection.modelID)?.supportsReasoningEffort ?? false
        return RealtimeSessionOptions(model: selection.modelID, reasoningEffort: supportsReasoning ? "low" : nil)
    }

    func transcribedSessionSettings() -> TranscribedAnswerSessionSettings {
        let selection = modelSelection(for: .anthropicClaude)
        let descriptor = AnswerModelCatalog.descriptor(provider: .anthropicClaude, modelID: selection.modelID)
        let maxTokens: Int = switch answerLength {
        case .short: 2_048
        case .standard: 4_096
        case .detailed: 8_192
        }
        return TranscribedAnswerSessionSettings(
            modelID: selection.modelID,
            systemInstructions: instructions(for: .transcriptText),
            triggerMode: answerTriggerMode,
            maxOutputTokens: maxTokens,
            reasoningEffort: descriptor?.supportsReasoningEffort == true ? "low" : nil,
            useServerSideFallback: anthropicServerSideFallback && descriptor?.supportsServerSideFallback == true
        )
    }
}
