import Foundation

actor AnswerContextWindow {
    private struct TrackedItem {
        let id: String
        let addedAt: Date
    }

    private var committedUserItemIDs: [TrackedItem] = []
    private var assistantOutputItemIDs: [String: [String]] = [:]
    private let maxAge: TimeInterval
    private let maxItemCount: Int
    private(set) var evictedItemCount = 0

    init(maxAge: TimeInterval = 300, maxItemCount: Int = 512) {
        self.maxAge = maxAge
        self.maxItemCount = maxItemCount
    }

    @discardableResult
    func trackCommittedUserItem(_ itemID: String) -> [String] {
        committedUserItemIDs.append(TrackedItem(id: itemID, addedAt: Date()))
        return evictIfNeeded()
    }

    func trackAssistantOutputItem(responseID: String, itemID: String) {
        assistantOutputItemIDs[responseID, default: []].append(itemID)
    }

    func takeAssistantOutputItems(responseID: String) -> [String] {
        assistantOutputItemIDs.removeValue(forKey: responseID) ?? []
    }

    func takeAllForCleanup(respondedResponseID: String) -> [String] {
        let userIDs = committedUserItemIDs.map(\.id)
        let outputIDs = assistantOutputItemIDs.removeValue(forKey: respondedResponseID) ?? []
        committedUserItemIDs.removeAll()
        assistantOutputItemIDs.removeAll()
        return userIDs + outputIDs
    }

    var committedItemCount: Int {
        committedUserItemIDs.count
    }

    private func evictIfNeeded() -> [String] {
        let cutoff = Date().addingTimeInterval(-maxAge)
        var evicted: [String] = []
        while let first = committedUserItemIDs.first, first.addedAt < cutoff {
            evicted.append(committedUserItemIDs.removeFirst().id)
            evictedItemCount += 1
        }
        while committedUserItemIDs.count > maxItemCount {
            evicted.append(committedUserItemIDs.removeFirst().id)
            evictedItemCount += 1
        }
        return evicted
    }
}
