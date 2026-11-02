import Foundation

public struct ExpertDomain: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public var name: String
    public var role: String
    public var guidance: String
    public var isActive: Bool
    public var sortOrder: Int
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        role: String = "",
        guidance: String = "",
        isActive: Bool = true,
        sortOrder: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.guidance = guidance
        self.isActive = isActive
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
    }

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func matches(folderName: String) -> Bool {
        Self.folderKey(name) == Self.folderKey(folderName)
    }

    public static func folderKey(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

public protocol ExpertDomainRepository: Sendable {
    func save(_ domain: ExpertDomain) async throws
    func delete(id: UUID) async throws
    func all() async throws -> [ExpertDomain]
}

public enum LegacyAnswerProfile: String, Sendable, Equatable {
    case automatic
    case phpBackend
    case systemDesign
    case behavioral
}

public enum ExpertDomainPresets {
    public static let phpBackendID = UUID(uuidString: "6C1F2A10-0000-4000-8000-000000000001")!
    public static let systemDesignID = UUID(uuidString: "6C1F2A10-0000-4000-8000-000000000002")!
    public static let behavioralID = UUID(uuidString: "6C1F2A10-0000-4000-8000-000000000003")!

    static let epoch = Date(timeIntervalSince1970: 0)

    public static let phpBackend = ExpertDomain(
        id: phpBackendID,
        name: "PHP / Backend",
        role: "A strong senior PHP and backend engineer answering interview questions about backend engineering.",
        guidance: """
        - Prefer concrete mechanisms (transactions and isolation levels, idempotency keys, queue retries and dead-letter handling, cache invalidation, N+1 and indexing, PHP-FPM and OPcache behaviour, Laravel/Yii2 internals when asked) over framework trivia.
        - When a framework feature is asked about, explain what it does underneath and its production pitfalls.
        """,
        sortOrder: 0,
        updatedAt: epoch
    )

    public static let systemDesign = ExpertDomain(
        id: systemDesignID,
        name: "System Design",
        role: "A senior architect answering system design interview questions.",
        guidance: """
        - Structure: explicit assumptions about requirements and load (labelled as assumptions), main components, data model and storage choice, the key trade-off, failure modes and recovery, how it scales, and one alternative design.
        - Prefer the simplest design that meets the stated constraints; justify every added component.
        """,
        sortOrder: 1,
        updatedAt: epoch
    )

    public static let behavioral = ExpertDomain(
        id: behavioralID,
        name: "Behavioral",
        role: "A senior engineer answering behavioral questions only from their own real experience.",
        guidance: """
        - Use only the real cases listed in the candidate background: situation, constraints, what was done, alternatives considered, result — without naming that structure.
        - If no listed case fits, say honestly that you don't have a directly matching case and describe how you would act, clearly as an approach rather than a past event.
        - Never invent a story, a team, an employer, a metric, or an outcome.
        """,
        sortOrder: 2,
        updatedAt: epoch
    )

    public static var interviewBuiltIns: [ExpertDomain] {
        [phpBackend, systemDesign, behavioral]
    }

    public static func seedPlan(existing: [ExpertDomain], legacyProfile: LegacyAnswerProfile?) -> [ExpertDomain] {
        let existingIDs = Set(existing.map(\.id))
        return interviewBuiltIns
            .filter { !existingIDs.contains($0.id) }
            .map { preset in
                var domain = preset
                domain.isActive = isActive(preset.id, under: legacyProfile)
                return domain
            }
    }

    static func isActive(_ id: UUID, under legacyProfile: LegacyAnswerProfile?) -> Bool {
        switch legacyProfile {
        case nil, .automatic?: true
        case .phpBackend?: id == phpBackendID
        case .systemDesign?: id == systemDesignID
        case .behavioral?: id == behavioralID
        }
    }
}
