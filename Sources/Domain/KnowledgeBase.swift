import Foundation

public enum KnowledgeNoteOrigin: String, Sendable, Codable, Equatable {
    case manual
    case folder
}

public struct KnowledgeNote: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var content: String
    public var isEnabled: Bool
    public var sourceFileName: String?
    public var domainID: UUID?
    public var origin: KnowledgeNoteOrigin
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        content: String,
        isEnabled: Bool = true,
        sourceFileName: String? = nil,
        domainID: UUID? = nil,
        origin: KnowledgeNoteOrigin = .manual,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.isEnabled = isEnabled
        self.sourceFileName = sourceFileName
        self.domainID = domainID
        self.origin = origin
        self.updatedAt = updatedAt
    }
}

public protocol KnowledgeNoteRepository: Sendable {
    func save(_ note: KnowledgeNote) async throws
    func delete(id: UUID) async throws
    func all() async throws -> [KnowledgeNote]
}

public struct KnowledgeContext: Sendable, Equatable {
    public let text: String
    public let includedNoteCount: Int
    public let truncatedNoteCount: Int
    public let activeDomainNames: [String]
    public let excludedByInactiveDomainCount: Int

    public init(text: String, includedNoteCount: Int, truncatedNoteCount: Int, activeDomainNames: [String] = [], excludedByInactiveDomainCount: Int = 0) {
        self.text = text
        self.includedNoteCount = includedNoteCount
        self.truncatedNoteCount = truncatedNoteCount
        self.activeDomainNames = activeDomainNames
        self.excludedByInactiveDomainCount = excludedByInactiveDomainCount
    }

    public static let empty = KnowledgeContext(text: "", includedNoteCount: 0, truncatedNoteCount: 0)
}

public enum KnowledgeContextBuilder {
    public static let defaultBudgetCharacters = 40_000

    public static func build(_ notes: [KnowledgeNote], budgetCharacters: Int = defaultBudgetCharacters) -> KnowledgeContext {
        let entries = notes.filter(\.isEnabled).map { (header: "## \($0.title)", body: $0.content) }
        return assemble(entries, budgetCharacters: budgetCharacters, activeDomainNames: [], excluded: 0)
    }

    public static func build(_ notes: [KnowledgeNote], domains: [ExpertDomain], budgetCharacters: Int = defaultBudgetCharacters) -> KnowledgeContext {
        let knownIDs = Set(domains.map(\.id))
        let active = domains.filter(\.isActive).sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        let enabled = notes.filter(\.isEnabled)
        var entries: [(header: String, body: String)] = []
        for note in enabled where note.domainID == nil || !knownIDs.contains(note.domainID!) {
            entries.append((header: "## \(note.title)", body: note.content))
        }
        for domain in active {
            for note in enabled where note.domainID == domain.id {
                entries.append((header: "## [\(domain.trimmedName)] \(note.title)", body: note.content))
            }
        }
        let excluded = enabled.filter { note in
            guard let id = note.domainID, knownIDs.contains(id) else { return false }
            return !active.contains { $0.id == id }
        }.count
        return assemble(entries, budgetCharacters: budgetCharacters, activeDomainNames: active.map(\.trimmedName), excluded: excluded)
    }

    private static func assemble(_ entries: [(header: String, body: String)], budgetCharacters: Int, activeDomainNames: [String], excluded: Int) -> KnowledgeContext {
        var parts: [String] = []
        var used = 0
        var included = 0
        var truncated = 0
        for entry in entries {
            let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let header = entry.header + "\n"
            let remaining = budgetCharacters - used - header.count
            guard remaining > 200 else {
                truncated += 1
                continue
            }
            if body.count > remaining {
                parts.append(header + String(body.prefix(remaining)) + "\n[…truncated]")
                used += header.count + remaining
                truncated += 1
            } else {
                parts.append(header + body)
                used += header.count + body.count
            }
            included += 1
        }
        return KnowledgeContext(
            text: parts.joined(separator: "\n\n"),
            includedNoteCount: included,
            truncatedNoteCount: truncated,
            activeDomainNames: activeDomainNames,
            excludedByInactiveDomainCount: excluded
        )
    }
}

public enum RecentAnswersMemory {
    public static func exchanges(from pairs: [QuestionAnswerPair], limit: Int) -> [PriorExchange] {
        guard limit > 0 else { return [] }
        let usable = pairs
            .filter { $0.status == .completed && !$0.answerText.isEmpty && ($0.questionText?.isEmpty == false) }
            .sorted { $0.askedAt > $1.askedAt }
            .prefix(limit)
        return usable.reversed().map {
            PriorExchange(
                question: SessionTranscriptContext.truncated($0.questionText ?? "", to: 400),
                answer: SessionTranscriptContext.truncated($0.answerText, to: 800)
            )
        }
    }
}

public final class LiveAnswerContext: @unchecked Sendable {
    private let lock = NSLock()
    private var knowledge = KnowledgeContext.empty
    private var exchanges: [PriorExchange] = []
    private var domains: [ExpertDomain] = []

    public init() {}

    public var knowledgeContext: KnowledgeContext {
        lock.withLock { knowledge }
    }

    public var recentExchanges: [PriorExchange] {
        lock.withLock { exchanges }
    }

    public var allDomains: [ExpertDomain] {
        lock.withLock { domains }
    }

    public var activeDomains: [ExpertDomain] {
        lock.withLock { domains.filter(\.isActive).sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) } }
    }

    public var activeDomainNames: [String] {
        activeDomains.map(\.trimmedName)
    }

    public func update(knowledge: KnowledgeContext) {
        lock.withLock { self.knowledge = knowledge }
    }

    public func update(recentExchanges: [PriorExchange]) {
        lock.withLock { exchanges = recentExchanges }
    }

    public func update(domains: [ExpertDomain]) {
        lock.withLock { self.domains = domains }
    }

    public var fingerprint: String {
        let joined = lock.withLock {
            let domainPart = domains.map { "\($0.id.uuidString)|\($0.isActive)|\($0.name)|\($0.role)|\($0.guidance)" }.joined(separator: "\u{1E}")
            return knowledge.text + "\u{1E}" + exchanges.map { $0.question + "\u{1F}" + $0.answer }.joined(separator: "\u{1E}") + "\u{1D}" + domainPart
        }
        return ContentFingerprint.of(joined)
    }
}

public enum ContentFingerprint {
    public static func of(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
