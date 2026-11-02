import Domain
import Foundation
import Testing
@testable import SecurityStore

final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    enum Failure: Error { case injected }
    private let lock = NSLock()
    private var value: String?
    var failStore = false
    var failRead = false
    var failDelete = false
    var corruptOnStore = false
    private(set) var storeCount = 0

    init(value: String? = nil) {
        self.value = value
    }

    func store(apiKey: String) throws {
        try lock.withLock {
            storeCount += 1
            if failStore { throw Failure.injected }
            value = corruptOnStore ? String(apiKey.dropLast()) : apiKey
        }
    }

    func retrieveAPIKey() throws -> String? {
        try lock.withLock {
            if failRead { throw Failure.injected }
            return value
        }
    }

    func deleteAPIKey() throws {
        try lock.withLock {
            if failDelete { throw Failure.injected }
            value = nil
        }
    }

    var rawValue: String? { lock.withLock { value } }
}

@Suite struct LegacyAPIKeyMigratorTests {
    let key = "sk-legacy-0123456789abcdef"

    @Test func migratesVerifiesThenDeletesLegacy() {
        let legacy = InMemorySecretStore(value: key)
        let keychain = InMemorySecretStore()
        #expect(LegacyAPIKeyMigrator(legacy: legacy, keychain: keychain).migrate() == .migrated)
        #expect(keychain.rawValue == key)
        #expect(legacy.rawValue == nil)
    }

    @Test func nothingToMigrateLeavesKeychainUntouched() {
        let keychain = InMemorySecretStore()
        #expect(LegacyAPIKeyMigrator(legacy: InMemorySecretStore(), keychain: keychain).migrate() == .nothingToMigrate)
        #expect(keychain.storeCount == 0)
    }

    @Test func keychainWriteFailureKeepsLegacyKey() {
        let legacy = InMemorySecretStore(value: key)
        let keychain = InMemorySecretStore()
        keychain.failStore = true
        #expect(LegacyAPIKeyMigrator(legacy: legacy, keychain: keychain).migrate() == .failedKeptLegacy(stage: "store_keychain"))
        #expect(legacy.rawValue == key)
    }

    @Test func verificationMismatchKeepsLegacyKey() {
        let legacy = InMemorySecretStore(value: key)
        let keychain = InMemorySecretStore()
        keychain.corruptOnStore = true
        #expect(LegacyAPIKeyMigrator(legacy: legacy, keychain: keychain).migrate() == .failedKeptLegacy(stage: "verify_mismatch"))
        #expect(legacy.rawValue == key)
    }

    @Test func unreadableKeychainKeepsLegacyKey() {
        let legacy = InMemorySecretStore(value: key)
        let keychain = InMemorySecretStore()
        keychain.failRead = true
        #expect(LegacyAPIKeyMigrator(legacy: legacy, keychain: keychain).migrate() == .failedKeptLegacy(stage: "read_keychain"))
        #expect(legacy.rawValue == key)
    }

    @Test func differentKeyAlreadyInKeychainKeepsBoth() {
        let legacy = InMemorySecretStore(value: key)
        let keychain = InMemorySecretStore(value: "sk-other-0123456789abcdef")
        #expect(LegacyAPIKeyMigrator(legacy: legacy, keychain: keychain).migrate() == .conflictKeptBoth)
        #expect(legacy.rawValue == key)
        #expect(keychain.rawValue == "sk-other-0123456789abcdef")
    }

    @Test func legacyDeleteFailureStillReportsKeyIsSafeInKeychain() {
        let legacy = InMemorySecretStore(value: key)
        legacy.failDelete = true
        let keychain = InMemorySecretStore()
        #expect(LegacyAPIKeyMigrator(legacy: legacy, keychain: keychain).migrate() == .migratedLegacyNotRemoved)
        #expect(keychain.rawValue == key)
    }

    @Test func outcomesNeverEmbedTheKey() {
        let legacy = InMemorySecretStore(value: key)
        let keychain = InMemorySecretStore()
        keychain.failStore = true
        let outcome = LegacyAPIKeyMigrator(legacy: legacy, keychain: keychain).migrate()
        #expect(!String(describing: outcome).contains(key))
    }

    @Test func keychainFirstStoreFallsBackToLegacyWhenMigrationFailed() throws {
        let legacy = InMemorySecretStore(value: key)
        let keychain = InMemorySecretStore()
        let store = KeychainFirstSecretStore(primary: keychain, legacyFallback: legacy)
        #expect(try store.retrieveAPIKey() == key)
        #expect(store.isUsingLegacyFallback)
        try store.store(apiKey: "sk-new-0123456789abcdefgh")
        #expect(try store.retrieveAPIKey() == "sk-new-0123456789abcdefgh")
        #expect(legacy.rawValue == nil)
        #expect(!store.isUsingLegacyFallback)
    }

    @Test func keychainFirstStoreRejectsUnverifiedWrite() {
        let keychain = InMemorySecretStore()
        keychain.corruptOnStore = true
        let store = KeychainFirstSecretStore(primary: keychain, legacyFallback: nil)
        #expect(throws: (any Error).self) { try store.store(apiKey: "sk-new-0123456789abcdefgh") }
    }

    @Test func realKeychainAndUserDefaultsMigrationRoundTrip() throws {
        let suite = "com.local.MeetingAssistant.tests.migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = UserDefaultsSecretStore(defaults: defaults)
        try legacy.store(apiKey: key)
        let keychain = KeychainSecretStore(service: "com.local.MeetingAssistant.tests", account: "migration-\(UUID().uuidString)")
        defer { try? keychain.deleteAPIKey() }
        #expect(LegacyAPIKeyMigrator(legacy: legacy, keychain: keychain).migrate() == .migrated)
        #expect(try keychain.retrieveAPIKey() == key)
        #expect(try legacy.retrieveAPIKey() == nil)
    }

    @Test func providerSpecificKeyFormats() {
        #expect(APIKeyFormatValidator.isPlausibleFormat("sk-ant-api03-abcdefghijklmnop", for: .anthropicClaude))
        #expect(!APIKeyFormatValidator.isPlausibleFormat("sk-proj-abcdefghijklmnopqrst", for: .anthropicClaude))
        #expect(APIKeyFormatValidator.isPlausibleFormat("sk-proj-abcdefghijklmnopqrst", for: .openAIRealtime))
        #expect(!APIKeyFormatValidator.isPlausibleFormat("sk-ant-api03-abcdefghijklmnop", for: .openAIRealtime))
        #expect(ProviderKeychainServices.service(for: .openAIRealtime) != ProviderKeychainServices.service(for: .anthropicClaude))
    }
}
