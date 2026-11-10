import Foundation

public enum ClaudeEffort: String, Sendable, Codable {
    case low, medium, high, xhigh, max
}

public enum ClaudeCacheTTL: String, Sendable {
    case fiveMinutes = "5m"
    case oneHour = "1h"
}

public struct ClaudeSystemBlock: Sendable, Equatable {
    public let text: String
    public let cacheTTL: ClaudeCacheTTL?

    public init(text: String, cacheTTL: ClaudeCacheTTL? = nil) {
        self.text = text
        self.cacheTTL = cacheTTL
    }
}

public enum ClaudeRole: String, Sendable, Codable {
    case user, assistant
}

public struct ClaudeMessage: Sendable, Equatable {
    public let role: ClaudeRole
    public let texts: [String]

    public init(role: ClaudeRole, texts: [String]) {
        self.role = role
        self.texts = texts
    }

    public static func user(_ texts: String...) -> ClaudeMessage { ClaudeMessage(role: .user, texts: texts) }
    public static func assistant(_ text: String) -> ClaudeMessage { ClaudeMessage(role: .assistant, texts: [text]) }
}

public struct ClaudeMessagesRequest: Sendable, Equatable {
    public var model: ClaudeModel
    public var maxTokens: Int
    public var stream: Bool
    public var effort: ClaudeEffort
    public var system: [ClaudeSystemBlock]
    public var messages: [ClaudeMessage]
    public var serverFallback: Bool

    public init(model: ClaudeModel, maxTokens: Int, stream: Bool = true, effort: ClaudeEffort = .low, system: [ClaudeSystemBlock], messages: [ClaudeMessage], serverFallback: Bool = true) {
        self.model = model
        self.maxTokens = maxTokens
        self.stream = stream
        self.effort = effort
        self.system = system
        self.messages = messages
        self.serverFallback = serverFallback
    }

    public var usesServerFallback: Bool {
        serverFallback && ClaudeModelCatalog.info(model).supportsServerFallback
    }

    public func validate() throws {
        if maxTokens < 0 || maxTokens > ClaudeModelCatalog.info(model).maxOutputTokens {
            throw ClaudeRequestError.invalidMaxTokens(maxTokens)
        }
        if maxTokens == 0, stream {
            throw ClaudeRequestError.prewarmMustNotStream
        }
        if system.filter({ $0.cacheTTL != nil }).count > 4 {
            throw ClaudeRequestError.tooManyCacheBreakpoints
        }
        var seenShorter = false
        for block in system {
            switch block.cacheTTL {
            case .fiveMinutes?: seenShorter = true
            case .oneHour?: if seenShorter { throw ClaudeRequestError.cacheTTLOrder }
            case nil: break
            }
        }
        guard let first = messages.first, first.role == .user else { throw ClaudeRequestError.firstMessageMustBeUser }
        if messages.last?.role != .user { throw ClaudeRequestError.lastMessageMustBeUser }
        for (previous, next) in zip(messages, messages.dropFirst()) where previous.role == next.role {
            throw ClaudeRequestError.rolesMustAlternate
        }
        if messages.contains(where: { $0.texts.isEmpty || $0.texts.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }) {
            throw ClaudeRequestError.emptyText
        }
    }

    public func body() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(WireRequest(self))
    }

    public func urlRequest(apiKey: String, endpoint: URL = ClaudeModelCatalog.endpoint, timeout: TimeInterval = 120) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try body()
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(ClaudeModelCatalog.apiVersion, forHTTPHeaderField: "anthropic-version")
        if usesServerFallback {
            request.setValue(ClaudeModelCatalog.serverFallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "accept")
        return request
    }
}

public enum ClaudeRequestError: Error, Sendable, Equatable {
    case invalidMaxTokens(Int)
    case prewarmMustNotStream
    case tooManyCacheBreakpoints
    case cacheTTLOrder
    case firstMessageMustBeUser
    case lastMessageMustBeUser
    case rolesMustAlternate
    case emptyText
}

private struct WireRequest: Encodable {
    let model: String
    let maxTokens: Int
    let stream: Bool?
    let thinking: Thinking
    let outputConfig: OutputConfig
    let system: [SystemBlock]
    let messages: [Message]
    let fallbacks: String?

    init(_ request: ClaudeMessagesRequest) {
        model = request.model.rawValue
        maxTokens = request.maxTokens
        stream = request.stream ? true : nil
        thinking = Thinking()
        outputConfig = OutputConfig(effort: request.effort.rawValue)
        system = request.system.map { SystemBlock(text: $0.text, cacheControl: $0.cacheTTL.map { CacheControl(ttl: $0.rawValue) }) }
        messages = request.messages.map { message in
            Message(role: message.role.rawValue, content: message.texts.map { TextBlock(text: $0) })
        }
        fallbacks = request.usesServerFallback ? "default" : nil
    }

    enum CodingKeys: String, CodingKey {
        case model, stream, thinking, system, messages, fallbacks
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
    }

    struct Thinking: Encodable { let type = "adaptive" }
    struct OutputConfig: Encodable { let effort: String }
    struct CacheControl: Encodable {
        let type = "ephemeral"
        let ttl: String
    }
    struct SystemBlock: Encodable {
        let type = "text"
        let text: String
        let cacheControl: CacheControl?
        enum CodingKeys: String, CodingKey {
            case type, text
            case cacheControl = "cache_control"
        }
    }
    struct TextBlock: Encodable {
        let type = "text"
        let text: String
    }
    struct Message: Encodable {
        let role: String
        let content: [TextBlock]
    }
}
