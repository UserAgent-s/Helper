import Foundation

public struct ClaudeUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int
    public var cacheCreation5mTokens: Int?
    public var cacheCreation1hTokens: Int?

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheCreationInputTokens: Int = 0, cacheReadInputTokens: Int = 0, cacheCreation5mTokens: Int? = nil, cacheCreation1hTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
    }

    public var totalPromptTokens: Int { inputTokens + cacheCreationInputTokens + cacheReadInputTokens }

    mutating func merge(_ wire: WireUsage) {
        if let v = wire.inputTokens { inputTokens = v }
        if let v = wire.outputTokens { outputTokens = v }
        if let v = wire.cacheCreationInputTokens { cacheCreationInputTokens = v }
        if let v = wire.cacheReadInputTokens { cacheReadInputTokens = v }
        if let breakdown = wire.cacheCreation {
            if let v = breakdown.ephemeral5m { cacheCreation5mTokens = v }
            if let v = breakdown.ephemeral1h { cacheCreation1hTokens = v }
        }
    }
}

struct WireUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreation: WireCacheCreation?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreation = "cache_creation"
    }
}

struct WireCacheCreation: Decodable {
    let ephemeral5m: Int?
    let ephemeral1h: Int?

    enum CodingKeys: String, CodingKey {
        case ephemeral5m = "ephemeral_5m_input_tokens"
        case ephemeral1h = "ephemeral_1h_input_tokens"
    }
}
