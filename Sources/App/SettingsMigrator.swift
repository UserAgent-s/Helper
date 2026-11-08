import AudioCapture
import Domain
import Foundation

struct SettingsMigrationReport: Equatable {
    var fromVersion: Int
    var toVersion: Int
    var systemAudioScopeMigrated: SystemAudioScope?
    var warnings: [String] = []
}

struct SettingsMigrator {
    static let currentVersion = 2
    static let schemaVersionKey = "com.local.UserAgent057.settings.schemaVersion"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    @discardableResult
    func migrateIfNeeded() -> SettingsMigrationReport {
        let storedVersion = defaults.object(forKey: Self.schemaVersionKey) as? Int ?? 1
        var report = SettingsMigrationReport(fromVersion: storedVersion, toVersion: storedVersion)
        guard storedVersion <= Self.currentVersion else {
            report.warnings.append("settings schema \(storedVersion) is newer than supported \(Self.currentVersion); left untouched")
            return report
        }
        if storedVersion < 2 {
            report.systemAudioScopeMigrated = migrateSystemAudioScope()
        }
        defaults.set(Self.currentVersion, forKey: Self.schemaVersionKey)
        report.toVersion = Self.currentVersion
        return report
    }

    private func migrateSystemAudioScope() -> SystemAudioScope {
        let legacyKey = UserDefaultsPreferredAudioSourceStore.legacyBundleIDKey
        let scope: SystemAudioScope
        if let existing = UserDefaultsPreferredAudioSourceStore.decodeScope(from: defaults) {
            scope = existing
        } else if let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty {
            scope = .application(bundleID: legacy, fallbackToWholeSystem: true)
        } else {
            scope = .defaultScope
        }
        UserDefaultsPreferredAudioSourceStore.encode(scope, into: defaults)
        defaults.removeObject(forKey: legacyKey)
        return scope
    }
}
