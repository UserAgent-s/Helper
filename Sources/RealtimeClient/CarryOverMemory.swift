import Foundation

struct CarryOverEntry: Sendable, Equatable {
    let responseID: String
    let questionItemIDs: [String]
    var questionParts: [String: String]
    let answer: String
    let completedAt: Date

    var question: String? {
        let text = questionItemIDs.compactMap { questionParts[$0] }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}

struct CarryOverMemory: Sendable {
    let capacity: Int
    let maxAge: TimeInterval
    private(set) var entries: [CarryOverEntry] = []

    init(capacity: Int = 2, maxAge: TimeInterval = 600) {
        self.capacity = max(0, capacity)
        self.maxAge = maxAge
    }

    mutating func append(_ entry: CarryOverEntry) {
        guard capacity > 0 else { return }
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    mutating func evictExpired(now: Date) -> Bool {
        let before = entries.count
        entries.removeAll { now.timeIntervalSince($0.completedAt) >= maxAge }
        return entries.count != before
    }

    mutating func attachTranscript(itemID: String, text: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.questionItemIDs.contains(itemID) }) else { return false }
        guard entries[index].questionParts[itemID] != text else { return false }
        entries[index].questionParts[itemID] = text
        return true
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    var renderedText: String? {
        RealtimeInstructions.carryOver(entries.map { ($0.question, $0.answer) })
    }
}
