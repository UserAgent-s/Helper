import Foundation
import Domain
import RealtimeClient
import Transcription
import Summary

enum SystemAudioBackend: String, CaseIterable {
    case screenCaptureKit
    case coreAudioTap
}

final class AppSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    private enum Keys {
        static let whisperModelID = "com.local.UserAgent057.settings.whisperModelID"
        static let summaryModelID = "com.local.UserAgent057.settings.summaryModelID"
        static let audioStorageEnabled = "com.local.UserAgent057.settings.audioStorageEnabled"
        static let historyRetentionDays = "com.local.UserAgent057.settings.historyRetentionDays"
        static let vadThreshold = "com.local.UserAgent057.settings.vadThreshold"
        static let vadPrefixPaddingMs = "com.local.UserAgent057.settings.vadPrefixPaddingMs"
        static let vadSilenceDurationMs = "com.local.UserAgent057.settings.vadSilenceDurationMs"
        static let onboardingCompleted = "com.local.UserAgent057.settings.onboardingCompleted"
        static let diagnosticsIncludeAudioStorageState = "com.local.UserAgent057.settings.diagnosticsOptIn"
        static let appLanguage = "com.local.UserAgent057.settings.appLanguage"
        static let answerLength = "com.local.UserAgent057.settings.answerLength"
        static let backgroundContext = "com.local.UserAgent057.settings.backgroundContext"
        static let deviceRole = "com.local.UserAgent057.settings.device.role"
        static let outputRoutePolicy = "com.local.UserAgent057.settings.audio.outputRoutePolicy"
        static let systemAudioBackend = "com.local.UserAgent057.settings.developer.systemAudioBackend"
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

    var deviceRole: DeviceRole {
        get { DeviceRole(rawValue: defaults.string(forKey: Keys.deviceRole) ?? "") ?? .primary }
        set { defaults.set(newValue.rawValue, forKey: Keys.deviceRole) }
    }

    var systemAudioBackend: SystemAudioBackend {
        get { SystemAudioBackend(rawValue: defaults.string(forKey: Keys.systemAudioBackend) ?? "") ?? .screenCaptureKit }
        set { defaults.set(newValue.rawValue, forKey: Keys.systemAudioBackend) }
    }

    var outputRoutePolicy: OutputRoutePolicy {
        get { OutputRoutePolicy(rawValue: defaults.string(forKey: Keys.outputRoutePolicy) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Keys.outputRoutePolicy) }
    }
}
