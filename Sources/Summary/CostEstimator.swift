public struct SummaryPricing: Sendable, Equatable {
    public let inputCostPerMillionTokensUSD: Double
    public let outputCostPerMillionTokensUSD: Double

    public init(inputCostPerMillionTokensUSD: Double, outputCostPerMillionTokensUSD: Double) {
        self.inputCostPerMillionTokensUSD = inputCostPerMillionTokensUSD
        self.outputCostPerMillionTokensUSD = outputCostPerMillionTokensUSD
    }
}

public enum SummaryPricingCatalog {
    public static let byModelID: [String: SummaryPricing] = [
        SummaryModelCatalog.defaultModelID: SummaryPricing(inputCostPerMillionTokensUSD: 5, outputCostPerMillionTokensUSD: 15),
        SummaryModelCatalog.economyModelID: SummaryPricing(inputCostPerMillionTokensUSD: 0.5, outputCostPerMillionTokensUSD: 1.5),
    ]
}

public struct SummaryCostEstimate: Sendable, Equatable {
    public let estimatedInputTokens: Int
    public let estimatedOutputTokens: Int
    public let estimatedCostUSD: Double
    public let isApproximate = true

    public init(estimatedInputTokens: Int, estimatedOutputTokens: Int, estimatedCostUSD: Double) {
        self.estimatedInputTokens = estimatedInputTokens
        self.estimatedOutputTokens = estimatedOutputTokens
        self.estimatedCostUSD = estimatedCostUSD
    }
}

public enum CostEstimator {
    private static let charactersPerToken = 2.5

    public static func estimateTokens(forCharacterCount characterCount: Int) -> Int {
        max(1, Int(Double(characterCount) / charactersPerToken))
    }

    public static func estimate(transcriptCharacterCount: Int, modelID: String, assumedOutputTokens: Int = 1500) -> SummaryCostEstimate {
        let inputTokens = estimateTokens(forCharacterCount: transcriptCharacterCount) + assumedOutputTokens / 10
        let pricing = SummaryPricingCatalog.byModelID[modelID] ?? SummaryPricing(inputCostPerMillionTokensUSD: 5, outputCostPerMillionTokensUSD: 15)
        let inputCost = Double(inputTokens) / 1_000_000 * pricing.inputCostPerMillionTokensUSD
        let outputCost = Double(assumedOutputTokens) / 1_000_000 * pricing.outputCostPerMillionTokensUSD
        return SummaryCostEstimate(
            estimatedInputTokens: inputTokens,
            estimatedOutputTokens: assumedOutputTokens,
            estimatedCostUSD: inputCost + outputCost
        )
    }
}
