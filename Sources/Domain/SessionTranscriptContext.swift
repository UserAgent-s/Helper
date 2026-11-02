import Foundation

public struct TranscriptFragment: Sendable, Equatable {
    public let sequence: Int
    public let text: String
    public let recognizedAt: Date

    public init(sequence: Int, text: String, recognizedAt: Date) {
        self.sequence = sequence
        self.text = text
        self.recognizedAt = recognizedAt
    }
}

public struct SessionTranscriptContext: Sendable {
    public let maxCharacters: Int
    public let maxPriorExchanges: Int
    public private(set) var fragments: [TranscriptFragment] = []
    public private(set) var priorExchanges: [PriorExchange] = []
    public private(set) var droppedFragmentCount = 0
    public private(set) var duplicateFragmentCount = 0
    private var nextSequence = 0

    static let knownHallucinations: Set<String> = [
        "продолжение следует",
        "субтитры сделал dimatorzok",
        "субтитры создавал dimatorzok",
        "спасибо за просмотр",
        "thank you for watching",
        "thanks for watching",
        "you",
    ]

    public init(maxCharacters: Int = 6_000, maxPriorExchanges: Int = 2) {
        self.maxCharacters = maxCharacters
        self.maxPriorExchanges = maxPriorExchanges
    }

    public var text: String {
        fragments.map(\.text).joined(separator: " ")
    }

    public var isEmpty: Bool {
        fragments.isEmpty
    }

    public var lastSequence: Int? {
        fragments.last?.sequence
    }

    @discardableResult
    public mutating func append(_ rawText: String, overlapsPrevious: Bool, at date: Date = Date()) -> TranscriptFragment? {
        var words = Self.words(in: rawText)
        guard !words.isEmpty else { return nil }
        let normalizedNew = Self.normalized(words)
        if Self.knownHallucinations.contains(normalizedNew.joined(separator: " ")) {
            return nil
        }

        if let last = fragments.last {
            let previousWords = Self.words(in: last.text)
            let previousNormalized = Self.normalized(previousWords)
            if normalizedNew == previousNormalized, date.timeIntervalSince(last.recognizedAt) < 5 {
                duplicateFragmentCount += 1
                return nil
            }
            let overlap = Self.boundaryOverlap(previous: previousNormalized, next: normalizedNew, minimum: overlapsPrevious ? 1 : 3)
            if overlap > 0 {
                words.removeFirst(overlap)
                duplicateFragmentCount += 1
            }
        }
        guard !words.isEmpty else { return nil }

        let fragment = TranscriptFragment(sequence: nextSequence, text: words.joined(separator: " "), recognizedAt: date)
        nextSequence += 1
        fragments.append(fragment)
        enforceLimit()
        return fragment
    }

    public mutating func consumeThrough(sequence: Int) {
        fragments.removeAll { $0.sequence <= sequence }
    }

    public mutating func recordExchange(question: String, answer: String) {
        priorExchanges.append(PriorExchange(question: Self.truncated(question, to: 600), answer: Self.truncated(answer, to: 1_200)))
        if priorExchanges.count > maxPriorExchanges {
            priorExchanges.removeFirst(priorExchanges.count - maxPriorExchanges)
        }
    }

    public mutating func clearAll() {
        fragments.removeAll()
        priorExchanges.removeAll()
        droppedFragmentCount = 0
        duplicateFragmentCount = 0
    }

    private mutating func enforceLimit() {
        while text.count > maxCharacters, fragments.count > 1 {
            fragments.removeFirst()
            droppedFragmentCount += 1
        }
    }

    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !normalize($0).isEmpty }
    }

    static func normalized(_ words: [String]) -> [String] {
        words.map(normalize)
    }

    static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    static func boundaryOverlap(previous: [String], next: [String], minimum: Int, maximum: Int = 12) -> Int {
        let limit = min(maximum, previous.count, next.count)
        guard limit >= minimum else { return 0 }
        for length in stride(from: limit, through: minimum, by: -1) {
            if Array(previous.suffix(length)) == Array(next.prefix(length)) {
                return length
            }
        }
        return 0
    }

    static func truncated(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
