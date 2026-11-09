import Foundation

public enum SessionSearchSource: String, Sendable, Equatable, CaseIterable {
    case utterance
    case questionAnswer = "question_answer"
    case screenText = "screen_text"
    case expansion
    case bookmark
}

public struct SessionSearchHit: Sendable, Equatable {
    public let sessionID: SessionID
    public let source: SessionSearchSource
    public let itemID: String
    public let snippet: String
    public let occurredAt: Date?
    public let rank: Double

    public init(sessionID: SessionID, source: SessionSearchSource, itemID: String, snippet: String, occurredAt: Date?, rank: Double) {
        self.sessionID = sessionID
        self.source = source
        self.itemID = itemID
        self.snippet = snippet
        self.occurredAt = occurredAt
        self.rank = rank
    }
}

public struct SessionSearchResult: Sendable, Equatable, Identifiable {
    public let sessionID: SessionID
    public let kind: SessionKind
    public let title: String?
    public let startedAt: Date
    public let hits: [SessionSearchHit]

    public var id: SessionID { sessionID }

    public init(sessionID: SessionID, kind: SessionKind, title: String?, startedAt: Date, hits: [SessionSearchHit]) {
        self.sessionID = sessionID
        self.kind = kind
        self.title = title
        self.startedAt = startedAt
        self.hits = hits
    }
}

public protocol SessionSearching: Sendable {
    func search(query: String, limit: Int) async throws -> [SessionSearchResult]
}
