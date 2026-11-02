import Foundation

public enum AnswerProvider: String, Codable, Sendable, CaseIterable {
    case openAIRealtime
    case anthropicClaude
}

public enum AnswerTriggerMode: String, Codable, Sendable, CaseIterable {
    case automatic
    case manualOnly
}

public struct AnswerModelSelection: Sendable, Equatable, Codable {
    public let provider: AnswerProvider
    public let modelID: String
    public let isCustom: Bool

    public init(provider: AnswerProvider, modelID: String, isCustom: Bool) {
        self.provider = provider
        self.modelID = modelID
        self.isCustom = isCustom
    }
}

public struct AnswerSessionConfiguration: Sendable, Equatable {
    public let selection: AnswerModelSelection
    public let triggerMode: AnswerTriggerMode
    public let answerLength: AnswerLength
    public let expertAreas: [String]
    public let profileFingerprint: String

    public init(
        selection: AnswerModelSelection,
        triggerMode: AnswerTriggerMode,
        answerLength: AnswerLength,
        expertAreas: [String] = [],
        profileFingerprint: String
    ) {
        self.selection = selection
        self.triggerMode = triggerMode
        self.answerLength = answerLength
        self.expertAreas = expertAreas
        self.profileFingerprint = profileFingerprint
    }
}

public enum ModelIDValidator {
    public static let maxLength = 100

    public static func isPlausible(_ modelID: String) -> Bool {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.count <= maxLength, trimmed == modelID else { return false }
        guard let first = trimmed.first, first.isLetter || first.isNumber else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:@")
        return trimmed.allSatisfy { allowed.contains($0) }
    }
}
