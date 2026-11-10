import Foundation
import Domain
import Testing
@testable import SecurityStore

@Suite struct UserDefaultsSecretStoreTests {

    private func freshStore() -> UserDefaultsSecretStore {
        let suiteName = "test-\(UUID().uuidString)"
        return UserDefaultsSecretStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    @Test func retrievingBeforeStoringReturnsNil() throws {
        let store = freshStore()
        #expect(try store.retrieveAPIKey() == nil)
    }

    @Test func storeThenRetrieveRoundTrips() throws {
        let store = freshStore()
        try store.store(apiKey: "sk-test-value-1234567890")
        #expect(try store.retrieveAPIKey() == "sk-test-value-1234567890")
    }

    @Test func storingTwiceUpdatesRatherThanDuplicating() throws {
        let store = freshStore()
        try store.store(apiKey: "sk-first-value-1234567890")
        try store.store(apiKey: "sk-second-value-1234567890")
        #expect(try store.retrieveAPIKey() == "sk-second-value-1234567890")
    }

    @Test func deleteThenRetrieveReturnsNil() throws {
        let store = freshStore()
        try store.store(apiKey: "sk-to-delete-1234567890")
        try store.deleteAPIKey()
        #expect(try store.retrieveAPIKey() == nil)
    }

    @Test func deletingWhenNothingStoredDoesNotThrow() throws {
        let store = freshStore()
        try store.deleteAPIKey()
    }
}

@Suite struct UserDefaultsSecretStoreProviderTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    @Test func legacyOpenAIKeyIsReadWithoutMigration() throws {
        let defaults = freshDefaults()
        defaults.set("sk-legacy-value-1234567890", forKey: "com.local.UserAgent057.settings.openaiAPIKey")
        let store = UserDefaultsSecretStore(defaults: defaults)
        #expect(try store.retrieveAPIKey(provider: .openAI) == "sk-legacy-value-1234567890")
        #expect(try store.retrieveAPIKey() == "sk-legacy-value-1234567890")
        #expect(try store.retrieveAPIKey(provider: .anthropic) == nil)
    }

    @Test func providersAreIsolated() throws {
        let store = UserDefaultsSecretStore(defaults: freshDefaults())
        try store.store(apiKey: "sk-openai-value-1234567890", provider: .openAI)
        try store.store(apiKey: "sk-ant-api03-anthropic-value-123456", provider: .anthropic)
        #expect(try store.retrieveAPIKey(provider: .openAI) == "sk-openai-value-1234567890")
        #expect(try store.retrieveAPIKey(provider: .anthropic) == "sk-ant-api03-anthropic-value-123456")
        try store.deleteAPIKey(provider: .anthropic)
        #expect(try store.retrieveAPIKey(provider: .anthropic) == nil)
        #expect(try store.retrieveAPIKey(provider: .openAI) == "sk-openai-value-1234567890")
    }

    @Test func anthropicKeyUsesItsOwnDefaultsKey() throws {
        let defaults = freshDefaults()
        let store = UserDefaultsSecretStore(defaults: defaults)
        try store.store(apiKey: "sk-ant-api03-anthropic-value-123456", provider: .anthropic)
        #expect(defaults.string(forKey: "com.local.UserAgent057.settings.anthropicAPIKey") == "sk-ant-api03-anthropic-value-123456")
        #expect(defaults.string(forKey: "com.local.UserAgent057.settings.openaiAPIKey") == nil)
    }
}
