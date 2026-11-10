import Foundation

public struct ClaudeCostBreakdown: Sendable, Equatable {
    public let input: Double
    public let cacheWrite: Double
    public let cacheRead: Double
    public let output: Double

    public var total: Double { input + cacheWrite + cacheRead + output }
}

public enum ClaudeCostEstimator {
    public static func estimate(_ usage: ClaudeUsage, model: ClaudeModel) -> ClaudeCostBreakdown {
        let pricing = ClaudeModelCatalog.info(model).pricing
        let longContext = pricing.longContextThresholdTokens.map { usage.totalPromptTokens > $0 } ?? false
        let inputRate = longContext ? (pricing.longContextInputPerMTok ?? pricing.inputPerMTok) : pricing.inputPerMTok
        let outputRate = longContext ? (pricing.longContextOutputPerMTok ?? pricing.outputPerMTok) : pricing.outputPerMTok
        let readRate = pricing.cacheReadPerMTok * (inputRate / pricing.inputPerMTok)
        let oneHour = usage.cacheCreation1hTokens ?? 0
        let fiveMinutes = usage.cacheCreation5mTokens ?? max(0, usage.cacheCreationInputTokens - oneHour)
        let writeTokens = Double(fiveMinutes) * ClaudeModelPricing.cacheWrite5mMultiplier + Double(oneHour) * ClaudeModelPricing.cacheWrite1hMultiplier
        return ClaudeCostBreakdown(
            input: perMTok(usage.inputTokens, inputRate),
            cacheWrite: writeTokens * inputRate / 1_000_000,
            cacheRead: perMTok(usage.cacheReadInputTokens, readRate),
            output: perMTok(usage.outputTokens, outputRate)
        )
    }

    private static func perMTok(_ tokens: Int, _ rate: Double) -> Double {
        Double(tokens) * rate / 1_000_000
    }
}
