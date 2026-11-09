import Foundation

extension ClientCommand {
    public struct HistoryList: Codable, Sendable, Equatable {
        public static let defaultLimit = 50
        public static let maxLimit = 100

        public let cursor: String?
        public let q: String?
        public let limit: Int?

        public init(cursor: String? = nil, q: String? = nil, limit: Int? = nil) {
            self.cursor = cursor
            self.q = q
            self.limit = limit
        }
    }

    public struct HistoryGet: Codable, Sendable, Equatable {
        public let sessionId: String

        public init(sessionId: String) {
            self.sessionId = sessionId
        }
    }
}

public struct HistoryHit: Codable, Sendable, Equatable {
    public let source: String
    public let itemId: String
    public let snippet: String
    public let at: Int64?

    public init(source: String, itemId: String, snippet: String, at: Int64? = nil) {
        self.source = source
        self.itemId = itemId
        self.snippet = snippet
        self.at = at
    }
}

public struct HistoryItem: Codable, Sendable, Equatable {
    public let sessionId: String
    public let kind: String
    public let title: String?
    public let startedAt: Int64
    public let endedAt: Int64?
    public let status: String?
    public let pinned: Bool?
    public let qaCount: Int?
    public let starCount: Int?
    public let hits: [HistoryHit]?

    public init(sessionId: String, kind: String, title: String?, startedAt: Int64, endedAt: Int64? = nil, status: String? = nil, pinned: Bool? = nil, qaCount: Int? = nil, starCount: Int? = nil, hits: [HistoryHit]? = nil) {
        self.sessionId = sessionId
        self.kind = kind
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.pinned = pinned
        self.qaCount = qaCount
        self.starCount = starCount
        self.hits = hits
    }
}

public struct HistoryExpansion: Codable, Sendable, Equatable {
    public let expansionId: String
    public let requestedAt: Int64
    public let model: String
    public let status: String
    public let text: String

    public init(expansionId: String, requestedAt: Int64, model: String, status: String, text: String) {
        self.expansionId = expansionId
        self.requestedAt = requestedAt
        self.model = model
        self.status = status
        self.text = text
    }
}

public struct HistoryQuestion: Codable, Sendable, Equatable {
    public let qaId: String
    public let askedAt: Int64
    public let question: String?
    public let answer: String
    public let status: String
    public let starred: Bool
    public let expansions: [HistoryExpansion]

    public init(qaId: String, askedAt: Int64, question: String?, answer: String, status: String, starred: Bool, expansions: [HistoryExpansion]) {
        self.qaId = qaId
        self.askedAt = askedAt
        self.question = question
        self.answer = answer
        self.status = status
        self.starred = starred
        self.expansions = expansions
    }
}

public struct HistoryLine: Codable, Sendable, Equatable {
    public let lineId: String
    public let speaker: WireSpeaker
    public let text: String
    public let translation: String?
    public let at: Int64?

    public init(lineId: String, speaker: WireSpeaker, text: String, translation: String? = nil, at: Int64? = nil) {
        self.lineId = lineId
        self.speaker = speaker
        self.text = text
        self.translation = translation
        self.at = at
    }
}

public struct HistoryMoment: Codable, Sendable, Equatable {
    public let bookmarkId: String
    public let kind: WireBookmarkKind
    public let markedAt: Int64
    public let qaId: String?
    public let note: String?

    public init(bookmarkId: String, kind: WireBookmarkKind, markedAt: Int64, qaId: String? = nil, note: String? = nil) {
        self.bookmarkId = bookmarkId
        self.kind = kind
        self.markedAt = markedAt
        self.qaId = qaId
        self.note = note
    }
}

public struct HistoryScreen: Codable, Sendable, Equatable {
    public let screenId: String
    public let capturedAt: Int64
    public let application: String?
    public let text: String

    public init(screenId: String, capturedAt: Int64, application: String?, text: String) {
        self.screenId = screenId
        self.capturedAt = capturedAt
        self.application = application
        self.text = text
    }
}

extension ServerEvent {
    public struct HistoryPage: Codable, Sendable, Equatable {
        public let q: String?
        public let cursor: String?
        public let items: [HistoryItem]
        public let nextCursor: String?

        public init(q: String? = nil, cursor: String? = nil, items: [HistoryItem], nextCursor: String? = nil) {
            self.q = q
            self.cursor = cursor
            self.items = items
            self.nextCursor = nextCursor
        }
    }

    public struct HistorySession: Codable, Sendable, Equatable {
        public let sessionId: String
        public let kind: String
        public let title: String?
        public let startedAt: Int64
        public let endedAt: Int64?
        public let status: String
        public let summary: String?
        public let qa: [HistoryQuestion]
        public let expansions: [HistoryExpansion]
        public let transcript: [HistoryLine]
        public let moments: [HistoryMoment]
        public let screens: [HistoryScreen]
        public let truncated: Bool

        public init(sessionId: String, kind: String, title: String?, startedAt: Int64, endedAt: Int64?, status: String, summary: String?, qa: [HistoryQuestion], expansions: [HistoryExpansion], transcript: [HistoryLine], moments: [HistoryMoment], screens: [HistoryScreen], truncated: Bool) {
            self.sessionId = sessionId
            self.kind = kind
            self.title = title
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.status = status
            self.summary = summary
            self.qa = qa
            self.expansions = expansions
            self.transcript = transcript
            self.moments = moments
            self.screens = screens
            self.truncated = truncated
        }

        public func withTranscript(_ lines: [HistoryLine], truncated: Bool) -> HistorySession {
            HistorySession(sessionId: sessionId, kind: kind, title: title, startedAt: startedAt, endedAt: endedAt, status: status, summary: summary, qa: qa, expansions: expansions, transcript: lines, moments: moments, screens: screens, truncated: truncated)
        }
    }
}
