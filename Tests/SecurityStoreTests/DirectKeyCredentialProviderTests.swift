import Domain
import Testing
@testable import SecurityStore

private struct FakeSecretStore: SecretStoring {
    var apiKey: String?

    func store(apiKey: String) throws {}
    func retrieveAPIKey() throws -> String? { apiKey }
    func deleteAPIKey() throws {}
}

@Suite struct DirectKeyCredentialProviderTests {

    @Test func returnsCredentialWhenKeyIsPresent() async throws {
        let provider = DirectKeyCredentialProvider(secretStoring: FakeSecretStore(apiKey: "sk-test"))
        let credential = try await provider.currentCredential()
        #expect(credential.apiKey == "sk-test")
    }

    @Test func throwsWhenNoKeyIsStored() async throws {
        let provider = DirectKeyCredentialProvider(secretStoring: FakeSecretStore(apiKey: nil))
        await #expect(throws: DirectKeyCredentialError.missingAPIKey) {
            _ = try await provider.currentCredential()
        }
    }
}
