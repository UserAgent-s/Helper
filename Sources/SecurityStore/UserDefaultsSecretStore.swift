import Domain
import Foundation

public struct UserDefaultsSecretStore: SecretStoring, @unchecked Sendable {
    private static let key = "com.local.UserAgent057.settings.openaiAPIKey"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func store(apiKey: String) throws {
        defaults.set(apiKey, forKey: Self.key)
    }

    public func retrieveAPIKey() throws -> String? {
        defaults.string(forKey: Self.key)
    }

    public func deleteAPIKey() throws {
        defaults.removeObject(forKey: Self.key)
    }
}
