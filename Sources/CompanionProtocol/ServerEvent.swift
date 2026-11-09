import Foundation

public enum ServerEvent: Sendable, Equatable {
    case helloOK(HelloOK)
    case pairOK(PairOK)
    case stateSnapshot(StateSnapshot)
    case modeChanged(ModeInfo)
    case notice(NoticeInfo)
    case level(LevelInfo)
    case transcriptDelta(TranscriptLine)
    case answerStarted(AnswerStarted)
    case answerDelta(AnswerDelta)
    case answerReplace(AnswerReplace)
    case answerDone(AnswerDone)
    case sessionStarted(SessionInfo)
    case sessionStopped(SessionStopped)
    case bookmarkAdded(BookmarkInfo)
    case bookmarkRemoved(BookmarkRemoved)
    case deepStarted(DeepStarted)
    case deepDelta(DeepDelta)
    case deepDone(DeepDone)
    case screenCaptured(ScreenCaptured)
    case exportReady(ExportReady)
    case historyPage(HistoryPage)
    case historySession(HistorySession)
    case ack(Ack)
    case error(ServerError)
    case pong(Pong)
    case unknown(type: String)

    public static let knownTypes: [String] = [
        "hello.ok", "pair.ok", "state.snapshot", "mode.changed", "notice", "level",
        "transcript.delta", "answer.started", "answer.delta", "answer.replace", "answer.done",
        "session.started", "session.stopped", "bookmark.added", "bookmark.removed", "deep.started", "deep.delta", "deep.done",
        "screen.captured", "export.ready", "history.page", "history.session", "ack", "error", "pong",
    ]

    public var type: String {
        switch self {
        case .helloOK: "hello.ok"
        case .pairOK: "pair.ok"
        case .stateSnapshot: "state.snapshot"
        case .modeChanged: "mode.changed"
        case .notice: "notice"
        case .level: "level"
        case .transcriptDelta: "transcript.delta"
        case .answerStarted: "answer.started"
        case .answerDelta: "answer.delta"
        case .answerReplace: "answer.replace"
        case .answerDone: "answer.done"
        case .sessionStarted: "session.started"
        case .sessionStopped: "session.stopped"
        case .bookmarkAdded: "bookmark.added"
        case .bookmarkRemoved: "bookmark.removed"
        case .deepStarted: "deep.started"
        case .deepDelta: "deep.delta"
        case .deepDone: "deep.done"
        case .screenCaptured: "screen.captured"
        case .exportReady: "export.ready"
        case .historyPage: "history.page"
        case .historySession: "history.session"
        case .ack: "ack"
        case .error: "error"
        case .pong: "pong"
        case .unknown(let type): type
        }
    }

    static func decode<K: CodingKey>(type: String, from container: KeyedDecodingContainer<K>, key: K) throws -> ServerEvent {
        func data<P: Decodable>(_ payload: P.Type) throws -> P {
            try container.decode(payload, forKey: key)
        }
        switch type {
        case "hello.ok": return .helloOK(try data(HelloOK.self))
        case "pair.ok": return .pairOK(try data(PairOK.self))
        case "state.snapshot": return .stateSnapshot(try data(StateSnapshot.self))
        case "mode.changed": return .modeChanged(try data(ModeInfo.self))
        case "notice": return .notice(try data(NoticeInfo.self))
        case "level": return .level(try data(LevelInfo.self))
        case "transcript.delta": return .transcriptDelta(try data(TranscriptLine.self))
        case "answer.started": return .answerStarted(try data(AnswerStarted.self))
        case "answer.delta": return .answerDelta(try data(AnswerDelta.self))
        case "answer.replace": return .answerReplace(try data(AnswerReplace.self))
        case "answer.done": return .answerDone(try data(AnswerDone.self))
        case "session.started": return .sessionStarted(try data(SessionInfo.self))
        case "session.stopped": return .sessionStopped(try data(SessionStopped.self))
        case "bookmark.added": return .bookmarkAdded(try data(BookmarkInfo.self))
        case "bookmark.removed": return .bookmarkRemoved(try data(BookmarkRemoved.self))
        case "deep.started": return .deepStarted(try data(DeepStarted.self))
        case "deep.delta": return .deepDelta(try data(DeepDelta.self))
        case "deep.done": return .deepDone(try data(DeepDone.self))
        case "screen.captured": return .screenCaptured(try data(ScreenCaptured.self))
        case "export.ready": return .exportReady(try data(ExportReady.self))
        case "history.page": return .historyPage(try data(HistoryPage.self))
        case "history.session": return .historySession(try data(HistorySession.self))
        case "ack": return .ack(try data(Ack.self))
        case "error": return .error(try data(ServerError.self))
        case "pong": return .pong(try container.decodeIfPresent(Pong.self, forKey: key) ?? Pong())
        default: return .unknown(type: type)
        }
    }

    func encodeData<K: CodingKey>(into container: inout KeyedEncodingContainer<K>, key: K) throws {
        switch self {
        case .helloOK(let p): try container.encode(p, forKey: key)
        case .pairOK(let p): try container.encode(p, forKey: key)
        case .stateSnapshot(let p): try container.encode(p, forKey: key)
        case .modeChanged(let p): try container.encode(p, forKey: key)
        case .notice(let p): try container.encode(p, forKey: key)
        case .level(let p): try container.encode(p, forKey: key)
        case .transcriptDelta(let p): try container.encode(p, forKey: key)
        case .answerStarted(let p): try container.encode(p, forKey: key)
        case .answerDelta(let p): try container.encode(p, forKey: key)
        case .answerReplace(let p): try container.encode(p, forKey: key)
        case .answerDone(let p): try container.encode(p, forKey: key)
        case .sessionStarted(let p): try container.encode(p, forKey: key)
        case .sessionStopped(let p): try container.encode(p, forKey: key)
        case .bookmarkAdded(let p): try container.encode(p, forKey: key)
        case .bookmarkRemoved(let p): try container.encode(p, forKey: key)
        case .deepStarted(let p): try container.encode(p, forKey: key)
        case .deepDelta(let p): try container.encode(p, forKey: key)
        case .deepDone(let p): try container.encode(p, forKey: key)
        case .screenCaptured(let p): try container.encode(p, forKey: key)
        case .exportReady(let p): try container.encode(p, forKey: key)
        case .historyPage(let p): try container.encode(p, forKey: key)
        case .historySession(let p): try container.encode(p, forKey: key)
        case .ack(let p): try container.encode(p, forKey: key)
        case .error(let p): try container.encode(p, forKey: key)
        case .pong(let p): try container.encode(p, forKey: key)
        case .unknown: try container.encode([String: String](), forKey: key)
        }
    }
}

extension ServerEvent {
    public struct HelloOK: Codable, Sendable, Equatable {
        public let deviceId: String
        public let protocolVersion: Int
        public let minClientVersion: Int
        public let serverVersion: String
        public let replayed: Bool

        public init(deviceId: String, serverVersion: String, replayed: Bool, protocolVersion: Int = CompanionProtocolVersion.current, minClientVersion: Int = CompanionProtocolVersion.minimumClient) {
            self.deviceId = deviceId
            self.protocolVersion = protocolVersion
            self.minClientVersion = minClientVersion
            self.serverVersion = serverVersion
            self.replayed = replayed
        }
    }

    public struct PairOK: Codable, Sendable, Equatable {
        public let deviceId: String
        public let deviceToken: String

        public init(deviceId: String, deviceToken: String) {
            self.deviceId = deviceId
            self.deviceToken = deviceToken
        }
    }

    public struct AnswerStarted: Codable, Sendable, Equatable {
        public let answerId: String
        public let trigger: WireTrigger
        public let startedAt: Int64

        public init(answerId: String, trigger: WireTrigger, startedAt: Int64) {
            self.answerId = answerId
            self.trigger = trigger
            self.startedAt = startedAt
        }
    }

    public struct AnswerDelta: Codable, Sendable, Equatable {
        public let answerId: String
        public let offset: Int
        public let text: String
        public let points: [AnswerPoint]?

        public init(answerId: String, offset: Int, text: String, points: [AnswerPoint]? = nil) {
            self.answerId = answerId
            self.offset = offset
            self.text = text
            self.points = points
        }
    }

    public struct AnswerReplace: Codable, Sendable, Equatable {
        public let answerId: String
        public let text: String
        public let points: [AnswerPoint]?

        public init(answerId: String, text: String, points: [AnswerPoint]? = nil) {
            self.answerId = answerId
            self.text = text
            self.points = points
        }
    }

    public struct AnswerDone: Codable, Sendable, Equatable {
        public let answerId: String
        public let status: WireAnswerStatus
        public let length: Int
        public let points: [AnswerPoint]?

        public init(answerId: String, status: WireAnswerStatus, length: Int, points: [AnswerPoint]? = nil) {
            self.answerId = answerId
            self.status = status
            self.length = length
            self.points = points
        }
    }

    public struct SessionStopped: Codable, Sendable, Equatable {
        public let sessionId: String
        public let endedAt: Int64
        public let reason: WireSessionStopReason?

        public init(sessionId: String, endedAt: Int64, reason: WireSessionStopReason? = nil) {
            self.sessionId = sessionId
            self.endedAt = endedAt
            self.reason = reason
        }
    }

    public struct ExportReady: Codable, Sendable, Equatable {
        public let sessionId: String
        public let url: String
        public let filename: String
        public let expiresAt: Int64

        public init(sessionId: String, url: String, filename: String, expiresAt: Int64) {
            self.sessionId = sessionId
            self.url = url
            self.filename = filename
            self.expiresAt = expiresAt
        }
    }

    public struct BookmarkRemoved: Codable, Sendable, Equatable {
        public let bookmarkId: String
        public let sessionId: String

        public init(bookmarkId: String, sessionId: String) {
            self.bookmarkId = bookmarkId
            self.sessionId = sessionId
        }
    }

    public struct DeepStarted: Codable, Sendable, Equatable {
        public let requestId: String
        public let pointId: String?
        public let model: WireDeepModel
        public let format: WireDeepFormat
        public let language: WireLanguage

        public init(requestId: String, pointId: String?, model: WireDeepModel, format: WireDeepFormat, language: WireLanguage) {
            self.requestId = requestId
            self.pointId = pointId
            self.model = model
            self.format = format
            self.language = language
        }
    }

    public struct DeepDelta: Codable, Sendable, Equatable {
        public let requestId: String
        public let offset: Int
        public let text: String

        public init(requestId: String, offset: Int, text: String) {
            self.requestId = requestId
            self.offset = offset
            self.text = text
        }
    }

    public struct DeepDone: Codable, Sendable, Equatable {
        public let requestId: String
        public let status: WireAnswerStatus
        public let errorCode: String?

        public init(requestId: String, status: WireAnswerStatus, errorCode: String? = nil) {
            self.requestId = requestId
            self.status = status
            self.errorCode = errorCode
        }
    }

    public struct ScreenCaptured: Codable, Sendable, Equatable {
        public let captureId: String
        public let capturedAt: Int64
        public let charCount: Int
        public let preview: String?

        public init(captureId: String, capturedAt: Int64, charCount: Int, preview: String? = nil) {
            self.captureId = captureId
            self.capturedAt = capturedAt
            self.charCount = charCount
            self.preview = preview
        }
    }

    public struct Ack: Codable, Sendable, Equatable {
        public let cmdId: String
        public let ok: Bool
        public let code: String?
        public let message: String?

        public init(cmdId: String, ok: Bool, code: String? = nil, message: String? = nil) {
            self.cmdId = cmdId
            self.ok = ok
            self.code = code
            self.message = message
        }
    }

    public struct ServerError: Codable, Sendable, Equatable {
        public let code: String
        public let message: String?
        public let fatal: Bool

        public init(code: String, message: String? = nil, fatal: Bool) {
            self.code = code
            self.message = message
            self.fatal = fatal
        }
    }

    public struct Pong: Codable, Sendable, Equatable {
        public let nonce: String?

        public init(nonce: String? = nil) {
            self.nonce = nonce
        }
    }
}
