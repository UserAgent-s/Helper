import Foundation

public enum InterviewAnswerProfile: String, Codable, Sendable, CaseIterable {
    case automatic
    case phpBackend
    case systemDesign
    case behavioral
}

public struct CandidateProfile: Codable, Sendable, Equatable {
    public var primaryStack: String
    public var realExperience: String
    public var realCases: String
    public var noCommercialExperience: String
    public var targetRole: String
    public var vacancyContext: String

    public init(
        primaryStack: String = "",
        realExperience: String = "",
        realCases: String = "",
        noCommercialExperience: String = "",
        targetRole: String = "",
        vacancyContext: String = ""
    ) {
        self.primaryStack = primaryStack
        self.realExperience = realExperience
        self.realCases = realCases
        self.noCommercialExperience = noCommercialExperience
        self.targetRole = targetRole
        self.vacancyContext = vacancyContext
    }

    public static let empty = CandidateProfile()

    public var isEmpty: Bool {
        [primaryStack, realExperience, realCases, noCommercialExperience, targetRole, vacancyContext]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var fingerprint: String {
        let joined = [primaryStack, realExperience, realCases, noCommercialExperience, targetRole, vacancyContext].joined(separator: "\u{1F}")
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in joined.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    public static func migratedFromLegacyBackground(_ background: String) -> CandidateProfile {
        CandidateProfile(realExperience: background.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static let caseTemplate = """
    Ситуация:
    Ограничения:
    Решение:
    Рассмотренные альтернативы:
    Результат (только проверяемый факт; если не измерялся — так и напишите):
    """
}
