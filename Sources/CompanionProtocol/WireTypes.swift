import Foundation

public enum WireMode: String, Codable, Sendable, CaseIterable {
    case passive
    case answers
    case recording
}

public enum WirePhase: String, Codable, Sendable, CaseIterable {
    case idle
    case starting
    case active
    case stopping
    case failed
}

public enum WireSpeaker: String, Codable, Sendable, CaseIterable {
    case them
    case me
}

public enum WireAudioSource: String, Codable, Sendable, CaseIterable {
    case system
    case me
}

public enum WireTrigger: String, Codable, Sendable, CaseIterable {
    case auto
    case manual
}

public enum WireAnswerStatus: String, Codable, Sendable, CaseIterable {
    case streaming
    case completed
    case cancelled
    case failed
}

public enum WireSeverity: String, Codable, Sendable, CaseIterable {
    case info
    case warning
    case error
}

public enum WireDeepFormat: String, Codable, Sendable, CaseIterable {
    case structured
    case short
    case steps
    case code
    case star
}

public enum WireDeepModel: String, Codable, Sendable, CaseIterable {
    case sonnet
    case opus
}

public enum WireLanguage: String, Codable, Sendable, CaseIterable {
    case auto
    case ru
    case en
    case both
}

public struct AnswerPoint: Codable, Sendable, Equatable {
    public let pointId: String
    public let index: Int
    public let start: Int
    public let end: Int
    public let open: Bool

    public init(pointId: String, index: Int, start: Int, end: Int, open: Bool) {
        self.pointId = pointId
        self.index = index
        self.start = start
        self.end = end
        self.open = open
    }
}

public struct ModeInfo: Codable, Sendable, Equatable {
    public let mode: WireMode
    public let phase: WirePhase
    public let startedAt: Int64?
    public let errorCode: String?

    public init(mode: WireMode, phase: WirePhase, startedAt: Int64? = nil, errorCode: String? = nil) {
        self.mode = mode
        self.phase = phase
        self.startedAt = startedAt
        self.errorCode = errorCode
    }
}

public struct LevelInfo: Codable, Sendable, Equatable {
    public let source: WireAudioSource
    public let rmsDBFS: Double
    public let peakDBFS: Double

    public init(source: WireAudioSource, rmsDBFS: Double, peakDBFS: Double) {
        self.source = source
        self.rmsDBFS = rmsDBFS
        self.peakDBFS = peakDBFS
    }
}

public struct NoticeInfo: Codable, Sendable, Equatable {
    public let code: String
    public let severity: WireSeverity
    public let message: String?
    public let args: [String: String]?

    public init(code: String, severity: WireSeverity, message: String? = nil, args: [String: String]? = nil) {
        self.code = code
        self.severity = severity
        self.message = message
        self.args = args
    }
}

public struct TranscriptLine: Codable, Sendable, Equatable {
    public let itemId: String
    public let speaker: WireSpeaker
    public let text: String
    public let isFinal: Bool
    public let language: String?
    public let translation: String?

    public init(itemId: String, speaker: WireSpeaker, text: String, isFinal: Bool, language: String? = nil, translation: String? = nil) {
        self.itemId = itemId
        self.speaker = speaker
        self.text = text
        self.isFinal = isFinal
        self.language = language
        self.translation = translation
    }
}

public enum WireSessionStopReason: String, Codable, Sendable, CaseIterable {
    case user
    case idle
}

public enum WireBookmarkKind: String, Codable, Sendable, CaseIterable {
    case star
    case moment
}

public struct SessionInfo: Codable, Sendable, Equatable {
    public let sessionId: String
    public let startedAt: Int64
    public let title: String?
    public let resumed: Bool?

    public init(sessionId: String, startedAt: Int64, title: String? = nil, resumed: Bool? = nil) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.title = title
        self.resumed = resumed
    }
}

public struct BookmarkInfo: Codable, Sendable, Equatable {
    public let bookmarkId: String
    public let sessionId: String
    public let kind: WireBookmarkKind
    public let markedAt: Int64
    public let answerId: String?
    public let note: String?

    public init(bookmarkId: String, sessionId: String, kind: WireBookmarkKind, markedAt: Int64, answerId: String? = nil, note: String? = nil) {
        self.bookmarkId = bookmarkId
        self.sessionId = sessionId
        self.kind = kind
        self.markedAt = markedAt
        self.answerId = answerId
        self.note = note
    }
}
