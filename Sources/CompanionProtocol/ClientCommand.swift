import Foundation

public struct ClientCommand: Sendable, Equatable {
    public let v: Int
    public let cmdId: String
    public let action: Action

    public init(cmdId: String, action: Action) {
        self.v = CompanionProtocolVersion.current
        self.cmdId = cmdId
        self.action = action
    }

    public var name: String { action.name }

    public enum Action: Sendable, Equatable {
        case hello(Hello)
        case pair(Pair)
        case ping(Ping)
        case answerNow
        case setMode(SetMode)
        case resetContext
        case expand(Expand)
        case captureScreen
        case sessionStart(SessionStart)
        case sessionStop
        case sessionResume(SessionResume)
        case starLast
        case markMoment(MarkMoment)
        case exportRequest(ExportRequest)
        case unknown(name: String)

        public static let knownNames: [String] = [
            "hello", "pair", "ping", "answer_now", "set_mode", "reset_context",
            "expand", "capture_screen", "session.start", "session.stop",
            "session.resume", "star_last", "mark_moment", "export.request",
        ]

        public var name: String {
            switch self {
            case .hello: "hello"
            case .pair: "pair"
            case .ping: "ping"
            case .answerNow: "answer_now"
            case .setMode: "set_mode"
            case .resetContext: "reset_context"
            case .expand: "expand"
            case .captureScreen: "capture_screen"
            case .sessionStart: "session.start"
            case .sessionStop: "session.stop"
            case .sessionResume: "session.resume"
            case .starLast: "star_last"
            case .markMoment: "mark_moment"
            case .exportRequest: "export.request"
            case .unknown(let name): name
            }
        }
    }

    public struct Hello: Codable, Sendable, Equatable {
        public let token: String
        public let lastSeq: Int?
        public let clientVersion: Int

        public init(token: String, lastSeq: Int? = nil, clientVersion: Int = CompanionProtocolVersion.current) {
            self.token = token
            self.lastSeq = lastSeq
            self.clientVersion = clientVersion
        }
    }

    public struct Pair: Codable, Sendable, Equatable {
        public let code: String
        public let deviceName: String

        public init(code: String, deviceName: String) {
            self.code = code
            self.deviceName = deviceName
        }
    }

    public struct Ping: Codable, Sendable, Equatable {
        public let nonce: String?

        public init(nonce: String? = nil) {
            self.nonce = nonce
        }
    }

    public struct SetMode: Codable, Sendable, Equatable {
        public let mode: WireMode

        public init(mode: WireMode) {
            self.mode = mode
        }
    }

    public struct Expand: Codable, Sendable, Equatable {
        public let pointId: String?
        public let freeText: String?
        public let format: WireDeepFormat?
        public let model: WireDeepModel?
        public let language: WireLanguage?

        public init(pointId: String? = nil, freeText: String? = nil, format: WireDeepFormat? = nil, model: WireDeepModel? = nil, language: WireLanguage? = nil) {
            self.pointId = pointId
            self.freeText = freeText
            self.format = format
            self.model = model
            self.language = language
        }
    }

    public struct SessionStart: Codable, Sendable, Equatable {
        public let title: String?

        public init(title: String? = nil) {
            self.title = title
        }
    }

    public struct SessionResume: Codable, Sendable, Equatable {
        public let sessionId: String

        public init(sessionId: String) {
            self.sessionId = sessionId
        }
    }

    public struct MarkMoment: Codable, Sendable, Equatable {
        public let note: String?

        public init(note: String? = nil) {
            self.note = note
        }
    }

    public struct ExportRequest: Codable, Sendable, Equatable {
        public let sessionId: String

        public init(sessionId: String) {
            self.sessionId = sessionId
        }
    }
}

extension ClientCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case v, cmdId, name, args
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .v)
        guard version == CompanionProtocolVersion.current else {
            throw CompanionProtocolError.unsupportedVersion(version)
        }
        v = version
        cmdId = try container.decode(String.self, forKey: .cmdId)
        let name = try container.decode(String.self, forKey: .name)
        func args<P: Decodable>(_ payload: P.Type) throws -> P {
            try container.decode(payload, forKey: .args)
        }
        switch name {
        case "hello": action = .hello(try args(Hello.self))
        case "pair": action = .pair(try args(Pair.self))
        case "ping": action = .ping(try container.decodeIfPresent(Ping.self, forKey: .args) ?? Ping())
        case "answer_now": action = .answerNow
        case "set_mode": action = .setMode(try args(SetMode.self))
        case "reset_context": action = .resetContext
        case "expand": action = .expand(try args(Expand.self))
        case "capture_screen": action = .captureScreen
        case "session.start": action = .sessionStart(try container.decodeIfPresent(SessionStart.self, forKey: .args) ?? SessionStart())
        case "session.stop": action = .sessionStop
        case "session.resume": action = .sessionResume(try args(SessionResume.self))
        case "star_last": action = .starLast
        case "mark_moment": action = .markMoment(try container.decodeIfPresent(MarkMoment.self, forKey: .args) ?? MarkMoment())
        case "export.request": action = .exportRequest(try args(ExportRequest.self))
        default: action = .unknown(name: name)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(cmdId, forKey: .cmdId)
        try container.encode(action.name, forKey: .name)
        switch action {
        case .hello(let p): try container.encode(p, forKey: .args)
        case .pair(let p): try container.encode(p, forKey: .args)
        case .ping(let p): try container.encode(p, forKey: .args)
        case .setMode(let p): try container.encode(p, forKey: .args)
        case .expand(let p): try container.encode(p, forKey: .args)
        case .sessionStart(let p): try container.encode(p, forKey: .args)
        case .sessionResume(let p): try container.encode(p, forKey: .args)
        case .markMoment(let p): try container.encode(p, forKey: .args)
        case .exportRequest(let p): try container.encode(p, forKey: .args)
        case .answerNow, .resetContext, .captureScreen, .sessionStop, .starLast, .unknown: break
        }
    }
}

extension ClientCommand {
    private static let identifierCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    public func validate() throws {
        try Self.identifier(cmdId, field: "cmdId", limit: CompanionLimits.maxCommandIDLength)
        switch action {
        case .hello(let hello):
            try Self.bounded(hello.token, field: "token", limit: CompanionLimits.maxTokenLength, allowEmpty: false)
            if let lastSeq = hello.lastSeq, lastSeq < 0 {
                throw CompanionProtocolError.invalidArgument(field: "lastSeq", reason: "negative")
            }
            guard hello.clientVersion >= 1 else {
                throw CompanionProtocolError.invalidArgument(field: "clientVersion", reason: "out_of_range")
            }
        case .pair(let pair):
            try Self.bounded(pair.code, field: "code", limit: CompanionLimits.maxPairingCodeLength, allowEmpty: false)
            try Self.bounded(pair.deviceName, field: "deviceName", limit: CompanionLimits.maxDeviceNameLength, allowEmpty: false)
        case .ping(let ping):
            if let nonce = ping.nonce {
                try Self.bounded(nonce, field: "nonce", limit: CompanionLimits.maxCommandIDLength, allowEmpty: true)
            }
        case .expand(let expand):
            if let pointId = expand.pointId {
                try Self.identifier(pointId, field: "pointId", limit: CompanionLimits.maxIdentifierLength)
            }
            if let freeText = expand.freeText {
                try Self.bounded(freeText, field: "freeText", limit: CompanionLimits.maxFreeTextLength, allowEmpty: false)
            }
            guard expand.pointId != nil || expand.freeText != nil else {
                throw CompanionProtocolError.invalidArgument(field: "pointId", reason: "required")
            }
        case .sessionStart(let start):
            if let title = start.title {
                try Self.bounded(title, field: "title", limit: CompanionLimits.maxSessionTitleLength, allowEmpty: true)
            }
        case .sessionResume(let resume):
            try Self.identifier(resume.sessionId, field: "sessionId", limit: CompanionLimits.maxIdentifierLength)
        case .markMoment(let mark):
            if let note = mark.note {
                try Self.bounded(note, field: "note", limit: CompanionLimits.maxMomentNoteLength, allowEmpty: true)
            }
        case .exportRequest(let request):
            try Self.identifier(request.sessionId, field: "sessionId", limit: CompanionLimits.maxIdentifierLength)
        case .unknown(let name):
            try Self.bounded(name, field: "name", limit: CompanionLimits.maxCommandNameLength, allowEmpty: false)
        case .answerNow, .setMode, .resetContext, .captureScreen, .sessionStop, .starLast:
            break
        }
    }

    private static func identifier(_ value: String, field: String, limit: Int) throws {
        try bounded(value, field: field, limit: limit, allowEmpty: false)
        guard value.unicodeScalars.allSatisfy(identifierCharacters.contains) else {
            throw CompanionProtocolError.invalidArgument(field: field, reason: "invalid_characters")
        }
    }

    private static func bounded(_ value: String, field: String, limit: Int, allowEmpty: Bool) throws {
        let length = value.utf16.count
        if !allowEmpty, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CompanionProtocolError.invalidArgument(field: field, reason: "empty")
        }
        guard length <= limit else {
            throw CompanionProtocolError.invalidArgument(field: field, reason: "too_long")
        }
    }
}
