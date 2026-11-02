import Domain
import Foundation

public enum LegacyKeyMigrationOutcome: Sendable, Equatable {
    case nothingToMigrate
    case migrated
    case migratedLegacyNotRemoved
    case alreadyInKeychainLegacyRemoved
    case conflictKeptBoth
    case failedKeptLegacy(stage: String)
}

public struct LegacyAPIKeyMigrator: Sendable {
    private let legacy: any SecretStoring
    private let keychain: any SecretStoring

    public init(legacy: any SecretStoring, keychain: any SecretStoring) {
        self.legacy = legacy
        self.keychain = keychain
    }

    public func migrate() -> LegacyKeyMigrationOutcome {
        guard let legacyKey = try? legacy.retrieveAPIKey(), !legacyKey.isEmpty else {
            return .nothingToMigrate
        }
        let existing: String?
        do {
            existing = try keychain.retrieveAPIKey()
        } catch {
            return .failedKeptLegacy(stage: "read_keychain")
        }
        if let existing, !existing.isEmpty {
            guard existing == legacyKey else { return .conflictKeptBoth }
            do {
                try legacy.deleteAPIKey()
                return .alreadyInKeychainLegacyRemoved
            } catch {
                return .migratedLegacyNotRemoved
            }
        }
        do {
            try keychain.store(apiKey: legacyKey)
        } catch {
            return .failedKeptLegacy(stage: "store_keychain")
        }
        let verified: String?
        do {
            verified = try keychain.retrieveAPIKey()
        } catch {
            return .failedKeptLegacy(stage: "verify_keychain")
        }
        guard verified == legacyKey else {
            return .failedKeptLegacy(stage: "verify_mismatch")
        }
        do {
            try legacy.deleteAPIKey()
        } catch {
            return .migratedLegacyNotRemoved
        }
        return .migrated
    }
}

public struct KeychainFirstSecretStore: SecretStoring, Sendable {
    private let primary: any SecretStoring
    private let legacyFallback: (any SecretStoring)?

    public init(primary: any SecretStoring, legacyFallback: (any SecretStoring)?) {
        self.primary = primary
        self.legacyFallback = legacyFallback
    }

    public func store(apiKey: String) throws {
        try primary.store(apiKey: apiKey)
        guard (try primary.retrieveAPIKey()) == apiKey else {
            throw KeychainError.unexpectedItemFormat
        }
        try? legacyFallback?.deleteAPIKey()
    }

    public func retrieveAPIKey() throws -> String? {
        if let value = try? primary.retrieveAPIKey(), !value.isEmpty {
            return value
        }
        if let legacyFallback, let value = try legacyFallback.retrieveAPIKey(), !value.isEmpty {
            return value
        }
        return nil
    }

    public func deleteAPIKey() throws {
        try primary.deleteAPIKey()
        try legacyFallback?.deleteAPIKey()
    }

    public var isUsingLegacyFallback: Bool {
        if let value = try? primary.retrieveAPIKey(), !value.isEmpty { return false }
        guard let legacyFallback, let value = try? legacyFallback.retrieveAPIKey() else { return false }
        return !value.isEmpty
    }
}
