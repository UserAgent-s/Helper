import AudioCapture
import Domain
import Foundation
import RealtimeClient
import Testing
@testable import UserAgent057

@Suite struct SettingsMigratorTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "settings-migrator-\(UUID().uuidString)")!
    }

    private func storedScope(_ defaults: UserDefaults) -> SystemAudioScope? {
        UserDefaultsPreferredAudioSourceStore.decodeScope(from: defaults)
    }

    @Test func absentKeyMigratesToWholeSystem() {
        let defaults = freshDefaults()
        let report = SettingsMigrator(defaults: defaults).migrateIfNeeded()
        #expect(report.fromVersion == 1)
        #expect(report.toVersion == 2)
        #expect(report.systemAudioScopeMigrated == .wholeSystem(excludingBundleIDs: []))
        #expect(storedScope(defaults) == .wholeSystem(excludingBundleIDs: []))
    }

    @Test func emptyKeyMigratesToWholeSystem() {
        let defaults = freshDefaults()
        defaults.set("", forKey: UserDefaultsPreferredAudioSourceStore.legacyBundleIDKey)
        SettingsMigrator(defaults: defaults).migrateIfNeeded()
        #expect(storedScope(defaults) == .wholeSystem(excludingBundleIDs: []))
        #expect(defaults.object(forKey: UserDefaultsPreferredAudioSourceStore.legacyBundleIDKey) == nil)
    }

    @Test func explicitBundleIDPreservedWithFallback() {
        let defaults = freshDefaults()
        defaults.set("com.google.Chrome", forKey: UserDefaultsPreferredAudioSourceStore.legacyBundleIDKey)
        SettingsMigrator(defaults: defaults).migrateIfNeeded()
        #expect(storedScope(defaults) == .application(bundleID: "com.google.Chrome", fallbackToWholeSystem: true))
    }

    @Test func migrationIsIdempotent() {
        let defaults = freshDefaults()
        defaults.set("com.apple.Safari", forKey: UserDefaultsPreferredAudioSourceStore.legacyBundleIDKey)
        SettingsMigrator(defaults: defaults).migrateIfNeeded()
        let second = SettingsMigrator(defaults: defaults).migrateIfNeeded()
        #expect(second.fromVersion == 2)
        #expect(second.systemAudioScopeMigrated == nil)
        #expect(storedScope(defaults) == .application(bundleID: "com.apple.Safari", fallbackToWholeSystem: true))
    }

    @Test func unknownFutureVersionIsLeftUntouched() {
        let defaults = freshDefaults()
        defaults.set(99, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set("com.apple.Safari", forKey: UserDefaultsPreferredAudioSourceStore.legacyBundleIDKey)
        let report = SettingsMigrator(defaults: defaults).migrateIfNeeded()
        #expect(report.toVersion == 99)
        #expect(!report.warnings.isEmpty)
        #expect(defaults.string(forKey: UserDefaultsPreferredAudioSourceStore.legacyBundleIDKey) == "com.apple.Safari")
        #expect(defaults.integer(forKey: SettingsMigrator.schemaVersionKey) == 99)
    }

    @Test func legacyBackgroundProviderReturnsTextUnchanged() async {
        let text = "Опыт: Swift, 10 лет"
        let provider = LegacyBackgroundProfileProvider { text }
        let digest = await provider.realtimeDigest()
        #expect(digest == text)
        #expect(RealtimeInstructions.system(for: .standard, background: digest) == RealtimeInstructions.system(for: .standard, background: text))
    }

    @Test func legacyBackgroundFingerprintTracksText() async {
        let first = await LegacyBackgroundProfileProvider { "A" }.fingerprint()
        let same = await LegacyBackgroundProfileProvider { "A" }.fingerprint()
        let other = await LegacyBackgroundProfileProvider { "B" }.fingerprint()
        #expect(first == same)
        #expect(first != other)
    }
}
