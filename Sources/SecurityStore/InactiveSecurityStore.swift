import Domain

public struct InactiveSecretStore: SecretStoring {
    public init() {}

    public func store(apiKey: String) throws {
        throw BootstrapUnavailableError.notYetImplemented("SecretStoring подключается на этапе 10")
    }

    public func retrieveAPIKey() throws -> String? {
        nil
    }

    public func deleteAPIKey() throws {}
}
