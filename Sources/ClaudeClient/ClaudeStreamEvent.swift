import Foundation

public enum ClaudeStopReason: Sendable, Equatable {
    case endTurn
    case maxTokens
    case stopSequence
    case refusal
    case pauseTurn
    case toolUse
    case other(String)

    init(wire: String) {
        switch wire {
        case "end_turn": self = .endTurn
        case "max_tokens": self = .maxTokens
        case "stop_sequence": self = .stopSequence
        case "refusal": self = .refusal
        case "pause_turn": self = .pauseTurn
        case "tool_use": self = .toolUse
        default: self = .other(wire)
        }
    }
}

public struct ClaudeCompletion: Sendable, Equatable {
    public let messageID: String
    public let model: String
    public let text: String
    public let stopReason: ClaudeStopReason
    public let usage: ClaudeUsage
}

public struct ClaudeRefusal: Sendable, Equatable {
    public let category: String?
    public let explanation: String?
    public let partialText: String
    public let model: String
    public let usage: ClaudeUsage
}

public enum ClaudeFailure: Error, Sendable, Equatable {
    case missingAPIKey
    case invalidRequest(ClaudeRequestError)
    case http(status: Int, type: String?, message: String?)
    case api(type: String, message: String?)
    case transport(String)
    case malformed(String)
    case incomplete

    public var isRetryable: Bool {
        switch self {
        case .http(let status, _, _): status == 408 || status == 409 || status == 429 || status >= 500
        case .api(let type, _): type == "overloaded_error" || type == "api_error" || type == "rate_limit_error"
        case .transport, .incomplete: true
        case .missingAPIKey, .invalidRequest, .malformed: false
        }
    }
}

public enum ClaudeStreamEvent: Sendable, Equatable {
    case started(messageID: String, model: String, usage: ClaudeUsage)
    case textDelta(String)
    case fallback(fromModel: String?, toModel: String?)
    case completed(ClaudeCompletion)
    case truncated(ClaudeCompletion)
    case refused(ClaudeRefusal)
    case failed(ClaudeFailure)

    public var isTerminal: Bool {
        switch self {
        case .completed, .truncated, .refused, .failed: true
        case .started, .textDelta, .fallback: false
        }
    }
}
