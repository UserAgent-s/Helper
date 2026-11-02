import Domain
import Foundation

public enum APIKeyFormatValidator {
    public static func isPlausibleFormat(_ apiKey: String) -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-") else { return false }
        guard trimmed.count >= 20 else { return false }
        let allowedCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return trimmed.allSatisfy { allowedCharacters.contains($0) }
    }

    public static func isPlausibleFormat(_ apiKey: String, for provider: AnswerProvider) -> Bool {
        guard isPlausibleFormat(apiKey) else { return false }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .openAIRealtime: return !trimmed.hasPrefix("sk-ant-")
        case .anthropicClaude: return trimmed.hasPrefix("sk-ant-")
        }
    }
}
