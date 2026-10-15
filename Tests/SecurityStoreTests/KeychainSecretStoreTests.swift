import Foundation
import Testing
@testable import SecurityStore

@Suite struct KeychainSecretStoreTests {

    private func uniqueStore() -> KeychainSecretStore {
        KeychainSecretStore(service: "com.local.MeetingAssistant.tests", account: "test-\(UUID().uuidString)")
    }

    @Test func retrievingBeforeStoringReturnsNil() throws {
        let store = uniqueStore()
        #expect(try store.retrieveAPIKey() == nil)
    }

    @Test func storeThenRetrieveRoundTrips() throws {
        let store = uniqueStore()
        try store.store(apiKey: "sk-test-value-1234567890")
        #expect(try store.retrieveAPIKey() == "sk-test-value-1234567890")
        try store.deleteAPIKey()
    }

    @Test func storingTwiceUpdatesRatherThanDuplicating() throws {
        let store = uniqueStore()
        try store.store(apiKey: "sk-first-value-1234567890")
        try store.store(apiKey: "sk-second-value-1234567890")
        #expect(try store.retrieveAPIKey() == "sk-second-value-1234567890")
        try store.deleteAPIKey()
    }

    @Test func deleteThenRetrieveReturnsNil() throws {
        let store = uniqueStore()
        try store.store(apiKey: "sk-to-delete-1234567890")
        try store.deleteAPIKey()
        #expect(try store.retrieveAPIKey() == nil)
    }

    @Test func deletingWhenNothingStoredDoesNotThrow() throws {
        let store = uniqueStore()
        try store.deleteAPIKey()
    }
}
