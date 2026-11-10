import Domain
import Foundation

public enum APIKeyCheck: Sendable, Equatable {
    case valid(String)
    case invalidFormat
    case belongsTo(SecretProvider)
}

public enum APIKeyFormatValidator {
    private static let anthropicPrefix = "sk-ant-"
    private static let allowedCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    public static func isPlausibleFormat(_ apiKey: String) -> Bool {
        isPlausibleFormat(apiKey, for: .openAI)
    }

    public static func isPlausibleFormat(_ apiKey: String, for provider: SecretProvider) -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20, trimmed.allSatisfy({ allowedCharacters.contains($0) }) else { return false }
        switch provider {
        case .openAI:
            return trimmed.hasPrefix("sk-") && !trimmed.hasPrefix(anthropicPrefix)
        case .anthropic:
            return trimmed.hasPrefix(anthropicPrefix) && trimmed.count > anthropicPrefix.count + 12
        }
    }

    public static func check(_ apiKey: String, for provider: SecretProvider) -> APIKeyCheck {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPlausibleFormat(trimmed, for: provider) { return .valid(trimmed) }
        if let other = likelyProvider(of: trimmed), other != provider { return .belongsTo(other) }
        return .invalidFormat
    }

    public static func likelyProvider(of apiKey: String) -> SecretProvider? {
        SecretProvider.allCases.first { isPlausibleFormat(apiKey, for: $0) }
    }
}
