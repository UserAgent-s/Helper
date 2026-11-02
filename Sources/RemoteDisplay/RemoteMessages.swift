import Domain
import Foundation

public struct RemoteHint: Codable, Sendable, Equatable {
    public struct Expansion: Codable, Sendable, Equatable {
        public let text: String
        public let status: String
        public let error: String?
    }

    public let id: UUID
    public let createdAt: Date
    public let question: String?
    public let text: String
    public let status: String
    public let error: String?
    public let expansion: Expansion?
    public let fromPreviousSession: Bool

    public init(_ hint: Hint) {
        id = hint.id
        createdAt = hint.createdAt
        question = hint.question
        text = hint.text
        (status, error) = RemoteHint.describe(hint.status)
        expansion = hint.expansion.map { expansion in
            let (status, error) = RemoteHint.describe(expansion.status)
            return Expansion(text: expansion.text, status: status, error: error)
        }
        fromPreviousSession = hint.fromPreviousSession
    }

    static func describe(_ status: HintTextStatus) -> (String, String?) {
        switch status {
        case .streaming: ("streaming", nil)
        case .completed: ("completed", nil)
        case .failed(let reason): ("failed", reason)
        }
    }
}

public struct RemoteSession: Codable, Sendable, Equatable {
    public let mode: String
    public let phase: String
    public let provider: String?
    public let modelID: String?
    public let expertAreas: [String]
    public let error: String?

    public init(_ state: HintSessionState) {
        mode = switch state.mode {
        case .passive: "passive"
        case .answers: "answers"
        case .recording: "recording"
        }
        phase = state.phase.rawValue
        provider = state.provider?.rawValue
        modelID = state.modelID
        expertAreas = state.expertAreas
        error = state.errorDescription
    }
}

public enum RemoteOutboundMessage: Sendable, Equatable {
    public static let protocolVersion = 1

    case hello
    case snapshot(hints: [RemoteHint], session: RemoteSession)
    case hintStarted(RemoteHint)
    case hintUpdated(RemoteHint)
    case hintCompleted(RemoteHint)
    case hintExpansion(hintID: UUID, expansion: RemoteHint.Expansion)
    case session(RemoteSession)
    case toast(code: String)
    case authFailed
    case pong

    public var type: String {
        switch self {
        case .hello: "hello"
        case .snapshot: "snapshot"
        case .hintStarted: "hint.started"
        case .hintUpdated: "hint.updated"
        case .hintCompleted: "hint.completed"
        case .hintExpansion: "hint.expansion"
        case .session: "session"
        case .toast: "toast"
        case .authFailed: "auth.failed"
        case .pong: "pong"
        }
    }

    public static func from(_ event: HintFeedEvent) -> RemoteOutboundMessage {
        switch event {
        case .snapshot(let hints, let session):
            .snapshot(hints: hints.map(RemoteHint.init), session: RemoteSession(session))
        case .hintStarted(let hint):
            .hintStarted(RemoteHint(hint))
        case .hintUpdated(let hint):
            .hintUpdated(RemoteHint(hint))
        case .hintCompleted(let hint):
            .hintCompleted(RemoteHint(hint))
        case .expansionUpdated(let hintID, let expansion):
            .hintExpansion(hintID: hintID, expansion: RemoteHint.Expansion(text: expansion.text, status: RemoteHint.describe(expansion.status).0, error: RemoteHint.describe(expansion.status).1))
        case .sessionChanged(let state):
            .session(RemoteSession(state))
        case .notice(let notice):
            .toast(code: notice.rawValue)
        }
    }
}

public enum RemoteInboundMessage: Sendable, Equatable {
    case auth(token: String)
    case answerNow
    case expand(hintID: UUID)
    case resetContext
    case setMode(AppMode)
    case ping
}

public enum RemoteCommand: Sendable, Equatable {
    case answerNow
    case expand(hintID: UUID)
    case resetContext
    case setMode(AppMode)
}

public enum RemoteMessageCodec {
    private struct Envelope: Encodable {
        let type: String
        let version: Int?
        let hints: [RemoteHint]?
        let session: RemoteSession?
        let hint: RemoteHint?
        let hintID: UUID?
        let expansion: RemoteHint.Expansion?
        let code: String?
    }

    private struct InboundEnvelope: Decodable {
        let type: String
        let token: String?
        let hintID: String?
        let mode: String?
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode(_ message: RemoteOutboundMessage) -> Data {
        var envelope = Envelope(type: message.type, version: nil, hints: nil, session: nil, hint: nil, hintID: nil, expansion: nil, code: nil)
        switch message {
        case .hello:
            envelope = Envelope(type: message.type, version: RemoteOutboundMessage.protocolVersion, hints: nil, session: nil, hint: nil, hintID: nil, expansion: nil, code: nil)
        case .snapshot(let hints, let session):
            envelope = Envelope(type: message.type, version: nil, hints: hints, session: session, hint: nil, hintID: nil, expansion: nil, code: nil)
        case .hintStarted(let hint), .hintUpdated(let hint), .hintCompleted(let hint):
            envelope = Envelope(type: message.type, version: nil, hints: nil, session: nil, hint: hint, hintID: nil, expansion: nil, code: nil)
        case .hintExpansion(let hintID, let expansion):
            envelope = Envelope(type: message.type, version: nil, hints: nil, session: nil, hint: nil, hintID: hintID, expansion: expansion, code: nil)
        case .session(let session):
            envelope = Envelope(type: message.type, version: nil, hints: nil, session: session, hint: nil, hintID: nil, expansion: nil, code: nil)
        case .toast(let code):
            envelope = Envelope(type: message.type, version: nil, hints: nil, session: nil, hint: nil, hintID: nil, expansion: nil, code: code)
        case .authFailed, .pong:
            break
        }
        return (try? encoder.encode(envelope)) ?? Data("{\"type\":\"\(message.type)\"}".utf8)
    }

    public static func decode(_ data: Data) -> RemoteInboundMessage? {
        guard let envelope = try? decoder.decode(InboundEnvelope.self, from: data) else { return nil }
        switch envelope.type {
        case "auth":
            guard let token = envelope.token else { return nil }
            return .auth(token: token)
        case "answer_now":
            return .answerNow
        case "expand":
            guard let id = envelope.hintID.flatMap(UUID.init(uuidString:)) else { return nil }
            return .expand(hintID: id)
        case "reset_context":
            return .resetContext
        case "set_mode":
            switch envelope.mode {
            case "passive": return .setMode(.passive)
            case "answers": return .setMode(.answers)
            case "recording": return .setMode(.recording)
            default: return nil
            }
        case "ping":
            return .ping
        default:
            return nil
        }
    }
}
