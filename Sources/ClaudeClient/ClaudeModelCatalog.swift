import Foundation

public enum ClaudeModel: String, Sendable, CaseIterable, Codable {
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"
    case haiku = "claude-haiku-5-5"
}

public struct ClaudeModelPricing: Sendable, Equatable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double
    public let cacheReadPerMTok: Double
    public let longContextThresholdTokens: Int?
    public let longContextInputPerMTok: Double?
    public let longContextOutputPerMTok: Double?

    public init(inputPerMTok: Double, outputPerMTok: Double, cacheReadPerMTok: Double, longContextThresholdTokens: Int? = nil, longContextInputPerMTok: Double? = nil, longContextOutputPerMTok: Double? = nil) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.longContextThresholdTokens = longContextThresholdTokens
        self.longContextInputPerMTok = longContextInputPerMTok
        self.longContextOutputPerMTok = longContextOutputPerMTok
    }

    public static let cacheWrite5mMultiplier = 1.25
    public static let cacheWrite1hMultiplier = 2.0
}

public struct ClaudeModelInfo: Sendable, Equatable {
    public let model: ClaudeModel
    public let displayName: String
    public let pricing: ClaudeModelPricing
    public let supportsServerFallback: Bool
    public let minimumCacheableTokens: Int
    public let maxOutputTokens: Int
}

public enum ClaudeModelCatalog {
    public static let apiVersion = "2026-10-21"
    public static let serverFallbackBeta = "server-side-fallback-2026-07-01"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let pricesCheckedOn = "2026-10-06"

    public static func info(_ model: ClaudeModel) -> ClaudeModelInfo {
        switch model {
        case .sonnet:
            ClaudeModelInfo(model: model, displayName: "Claude Sonnet 5.5", pricing: ClaudeModelPricing(inputPerMTok: 2.0, outputPerMTok: 10.0, cacheReadPerMTok: 0.20), supportsServerFallback: true, minimumCacheableTokens: 512, maxOutputTokens: 128_000)
        case .opus:
            ClaudeModelInfo(model: model, displayName: "Claude Opus 5.5", pricing: ClaudeModelPricing(inputPerMTok: 4.0, outputPerMTok: 20.0, cacheReadPerMTok: 0.20), supportsServerFallback: true, minimumCacheableTokens: 512, maxOutputTokens: 128_000)
        case .haiku:
            ClaudeModelInfo(model: model, displayName: "Claude Haiku 5.5", pricing: ClaudeModelPricing(inputPerMTok: 0.10, outputPerMTok: 0.50, cacheReadPerMTok: 0.01, longContextThresholdTokens: 100_000, longContextInputPerMTok: 0.50, longContextOutputPerMTok: 2.50), supportsServerFallback: false, minimumCacheableTokens: 512, maxOutputTokens: 128_000)
        }
    }

    public static func info(modelID: String) -> ClaudeModelInfo? {
        ClaudeModel(rawValue: modelID).map(info)
    }
}
