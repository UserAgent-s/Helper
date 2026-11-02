import Foundation

public struct KnowledgeNote: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var content: String
    public var isEnabled: Bool
    public var sourceFileName: String?
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, content: String, isEnabled: Bool = true, sourceFileName: String? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.isEnabled = isEnabled
        self.sourceFileName = sourceFileName
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

    public static let empty = KnowledgeContext(text: "", includedNoteCount: 0, truncatedNoteCount: 0)
}

public enum KnowledgeContextBuilder {
    public static let defaultBudgetCharacters = 40_000

    public static func build(_ notes: [KnowledgeNote], budgetCharacters: Int = defaultBudgetCharacters) -> KnowledgeContext {
        var parts: [String] = []
        var used = 0
        var included = 0
        var truncated = 0
        for note in notes where note.isEnabled {
            let body = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let header = "## \(note.title)\n"
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
        return KnowledgeContext(text: parts.joined(separator: "\n\n"), includedNoteCount: included, truncatedNoteCount: truncated)
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

    public init() {}

    public var knowledgeContext: KnowledgeContext {
        lock.withLock { knowledge }
    }

    public var recentExchanges: [PriorExchange] {
        lock.withLock { exchanges }
    }

    public func update(knowledge: KnowledgeContext) {
        lock.withLock { self.knowledge = knowledge }
    }

    public func update(recentExchanges: [PriorExchange]) {
        lock.withLock { exchanges = recentExchanges }
    }

    public var fingerprint: String {
        let joined = lock.withLock { knowledge.text + "\u{1E}" + exchanges.map { $0.question + "\u{1F}" + $0.answer }.joined(separator: "\u{1E}") }
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
