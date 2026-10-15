import Foundation
import Domain
import RealtimeClient
import Transcription
import Summary

final class AppSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

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
}
