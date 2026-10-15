import Foundation
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
