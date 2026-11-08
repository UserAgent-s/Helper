import Domain
import Foundation
import Security

public enum KeychainError: Error, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
    case unexpectedItemFormat
}

public struct KeychainSecretStore: SecretStoring, Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.local.MeetingAssistant.openai", account: String = "default") {
        self.service = service
        self.account = account
    }

    public func store(apiKey: String) throws {
        let data = Data(apiKey.utf8)
        var query = baseQuery()
        if try readData() != nil {
            let attributesToUpdate: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        } else {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        }
    }

    public func retrieveAPIKey() throws -> String? {
        guard let data = try readData() else { return nil }
        guard let apiKey = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedItemFormat
        }
        return apiKey
    }

    public func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func readData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.unexpectedItemFormat
        }
        return data
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
