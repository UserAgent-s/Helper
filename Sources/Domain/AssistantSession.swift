import Foundation

public typealias SessionID = MeetingID

public enum SessionKind: String, Sendable, Equatable, CaseIterable {
    case assistant
    case recording
}

public enum SessionSpanMode: String, Sendable, Equatable, CaseIterable {
    case answers
    case recording

    public init?(_ mode: AppMode) {
        switch mode {
        case .answers: self = .answers
        case .recording: self = .recording
        case .passive: return nil
        }
    }
}

public enum SessionSpanEndReason: String, Sendable, Equatable, CaseIterable {
    case stopped
    case modeChanged
    case autoStopped
    case interrupted
    case legacy
}

public enum SessionTitleSource: String, Sendable, Equatable, CaseIterable {
    case heuristic
    case user
    case summary
    case legacy
}

public enum UtteranceOrigin: String, Sendable, Equatable, CaseIterable {
    case realtimeInput = "realtime_input"
    case meChannel = "me_channel"
    case whisperLocal = "whisper_local"
}

public enum BookmarkKind: String, Sendable, Equatable, CaseIterable {
    case star
    case moment
}

public struct SessionSpan: Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: SessionID
    public let mode: SessionSpanMode
    public let startedAt: Date
    public var endedAt: Date?
    public var endReason: SessionSpanEndReason?

    public init(id: String = "span_\(UUID().uuidString)", sessionID: SessionID, mode: SessionSpanMode, startedAt: Date, endedAt: Date? = nil, endReason: SessionSpanEndReason? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.mode = mode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
    }

    public var isOpen: Bool { endedAt == nil }
}

public struct AssistantSession: Sendable, Equatable, Identifiable {
    public let id: SessionID
    public let kind: SessionKind
    public var title: String?
    public var titleSource: SessionTitleSource?
    public let startedAt: Date
    public var endedAt: Date?
    public var status: MeetingStatus
    public var pinned: Bool
    public var lastActivityAt: Date
    public var spans: [SessionSpan]

    public init(id: SessionID, kind: SessionKind, title: String? = nil, titleSource: SessionTitleSource? = nil, startedAt: Date, endedAt: Date? = nil, status: MeetingStatus, pinned: Bool = false, lastActivityAt: Date, spans: [SessionSpan] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.titleSource = titleSource
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.pinned = pinned
        self.lastActivityAt = lastActivityAt
        self.spans = spans
    }

    public var openSpan: SessionSpan? { spans.last(where: \.isOpen) }
}

public struct SessionHeader: Sendable, Equatable, Identifiable {
    public let id: SessionID
    public let kind: SessionKind
    public let title: String?
    public let startedAt: Date
    public let endedAt: Date?
    public let status: MeetingStatus
    public let pinned: Bool
    public let lastActivityAt: Date
    public let questionAnswerCount: Int
    public let starCount: Int

    public init(id: SessionID, kind: SessionKind, title: String?, startedAt: Date, endedAt: Date?, status: MeetingStatus, pinned: Bool, lastActivityAt: Date, questionAnswerCount: Int, starCount: Int) {
        self.id = id
        self.kind = kind
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.pinned = pinned
        self.lastActivityAt = lastActivityAt
        self.questionAnswerCount = questionAnswerCount
        self.starCount = starCount
    }
}

public struct SessionCursor: Sendable, Equatable, Hashable {
    public let startedAt: Date
    public let id: SessionID

    public init(startedAt: Date, id: SessionID) {
        self.startedAt = startedAt
        self.id = id
    }
}

public struct SessionPage: Sendable, Equatable {
    public let headers: [SessionHeader]
    public let nextCursor: SessionCursor?

    public init(headers: [SessionHeader], nextCursor: SessionCursor?) {
        self.headers = headers
        self.nextCursor = nextCursor
    }
}

public struct SessionBookmark: Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: SessionID
    public let kind: BookmarkKind
    public let questionAnswerID: UUID?
    public let markedAt: Date
    public let note: String?

    public init(id: String = "bm_\(UUID().uuidString)", sessionID: SessionID, kind: BookmarkKind, questionAnswerID: UUID? = nil, markedAt: Date, note: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.questionAnswerID = questionAnswerID
        self.markedAt = markedAt
        self.note = note
    }
}

public struct SessionUtterance: Sendable, Equatable, Identifiable {
    public let id: String
    public let speaker: Speaker
    public let origin: UtteranceOrigin
    public let text: String
    public let capturedAt: Date?
    public let language: String?
    public let translationText: String?
    public let translationLanguage: String?

    public init(id: String, speaker: Speaker, origin: UtteranceOrigin, text: String, capturedAt: Date?, language: String? = nil, translationText: String? = nil, translationLanguage: String? = nil) {
        self.id = id
        self.speaker = speaker
        self.origin = origin
        self.text = text
        self.capturedAt = capturedAt
        self.language = language
        self.translationText = translationText
        self.translationLanguage = translationLanguage
    }
}

public struct SessionScreenContext: Sendable, Equatable, Identifiable {
    public let id: String
    public let capturedAt: Date
    public let application: String?
    public let windowTitle: String?
    public let text: String

    public init(id: String, capturedAt: Date, application: String?, windowTitle: String?, text: String) {
        self.id = id
        self.capturedAt = capturedAt
        self.application = application
        self.windowTitle = windowTitle
        self.text = text
    }
}

public struct SessionExpansion: Sendable, Equatable, Identifiable {
    public let id: String
    public let questionAnswerID: UUID?
    public let requestedAt: Date
    public let modelID: String
    public let status: String
    public let text: String

    public init(id: String, questionAnswerID: UUID?, requestedAt: Date, modelID: String, status: String, text: String) {
        self.id = id
        self.questionAnswerID = questionAnswerID
        self.requestedAt = requestedAt
        self.modelID = modelID
        self.status = status
        self.text = text
    }
}

public struct SessionDetail: Sendable, Equatable {
    public let session: AssistantSession
    public let utterances: [SessionUtterance]
    public let questionAnswers: [QuestionAnswerPair]
    public let bookmarks: [SessionBookmark]
    public let expansions: [SessionExpansion]
    public let screenContexts: [SessionScreenContext]

    public init(session: AssistantSession, utterances: [SessionUtterance], questionAnswers: [QuestionAnswerPair], bookmarks: [SessionBookmark], expansions: [SessionExpansion], screenContexts: [SessionScreenContext]) {
        self.session = session
        self.utterances = utterances
        self.questionAnswers = questionAnswers
        self.bookmarks = bookmarks
        self.expansions = expansions
        self.screenContexts = screenContexts
    }
}
