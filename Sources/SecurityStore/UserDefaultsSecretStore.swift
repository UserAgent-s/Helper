import Domain
import Foundation

public struct UserDefaultsSecretStore: SecretStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func defaultsKey(for provider: SecretProvider) -> String {
        switch provider {
        case .openAI: "com.local.UserAgent057.settings.openaiAPIKey"
        case .anthropic: "com.local.UserAgent057.settings.anthropicAPIKey"
        }
    }

    public func store(apiKey: String, provider: SecretProvider) throws {
        defaults.set(apiKey, forKey: Self.defaultsKey(for: provider))
    }

    public func retrieveAPIKey(provider: SecretProvider) throws -> String? {
        defaults.string(forKey: Self.defaultsKey(for: provider))
    }

    public func deleteAPIKey(provider: SecretProvider) throws {
        defaults.removeObject(forKey: Self.defaultsKey(for: provider))
    }
}
