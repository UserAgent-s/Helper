import Domain

public struct InactiveSecretStore: SecretStoring {
    public init() {}

    public func store(apiKey: String, provider: SecretProvider) throws {
        throw BootstrapUnavailableError.notYetImplemented("SecretStoring подключается на этапе 10")
    }

    public func retrieveAPIKey(provider: SecretProvider) throws -> String? {
        nil
    }

    public func deleteAPIKey(provider: SecretProvider) throws {}
}
