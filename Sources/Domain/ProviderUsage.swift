import Foundation

public struct ProviderUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int?
    public var inputTextTokens: Int?
    public var inputAudioTokens: Int?
    public var cachedInputTokens: Int?
    public var cachedTextTokens: Int?
    public var cachedAudioTokens: Int?
    public var cacheCreationInputTokens: Int?
    public var outputTokens: Int?
    public var outputTextTokens: Int?
    public var reasoningTokens: Int?

    public init(
        inputTokens: Int? = nil,
        inputTextTokens: Int? = nil,
        inputAudioTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cachedTextTokens: Int? = nil,
        cachedAudioTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        outputTokens: Int? = nil,
        outputTextTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.inputTextTokens = inputTextTokens
        self.inputAudioTokens = inputAudioTokens
        self.cachedInputTokens = cachedInputTokens
        self.cachedTextTokens = cachedTextTokens
        self.cachedAudioTokens = cachedAudioTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.outputTokens = outputTokens
        self.outputTextTokens = outputTextTokens
        self.reasoningTokens = reasoningTokens
    }

    public var isEmpty: Bool {
        self == ProviderUsage()
    }

    public static func + (lhs: ProviderUsage, rhs: ProviderUsage) -> ProviderUsage {
        ProviderUsage(
            inputTokens: sum(lhs.inputTokens, rhs.inputTokens),
            inputTextTokens: sum(lhs.inputTextTokens, rhs.inputTextTokens),
            inputAudioTokens: sum(lhs.inputAudioTokens, rhs.inputAudioTokens),
            cachedInputTokens: sum(lhs.cachedInputTokens, rhs.cachedInputTokens),
            cachedTextTokens: sum(lhs.cachedTextTokens, rhs.cachedTextTokens),
            cachedAudioTokens: sum(lhs.cachedAudioTokens, rhs.cachedAudioTokens),
            cacheCreationInputTokens: sum(lhs.cacheCreationInputTokens, rhs.cacheCreationInputTokens),
            outputTokens: sum(lhs.outputTokens, rhs.outputTokens),
            outputTextTokens: sum(lhs.outputTextTokens, rhs.outputTextTokens),
            reasoningTokens: sum(lhs.reasoningTokens, rhs.reasoningTokens)
        )
    }

    private static func sum(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case (nil, nil): nil
        case (let a?, nil): a
        case (nil, let b?): b
        case (let a?, let b?): a + b
        }
    }
}

public struct ModelPricing: Sendable, Equatable {
    public let textInputPerMillionUSD: Double
    public let audioInputPerMillionUSD: Double?
    public let cachedTextInputPerMillionUSD: Double?
    public let cachedAudioInputPerMillionUSD: Double?
    public let cacheWritePerMillionUSD: Double?
    public let textOutputPerMillionUSD: Double
    public let sourceURL: String
    public let verifiedOn: String
    public let note: String?

    public init(
        textInputPerMillionUSD: Double,
        audioInputPerMillionUSD: Double? = nil,
        cachedTextInputPerMillionUSD: Double?,
        cachedAudioInputPerMillionUSD: Double? = nil,
        cacheWritePerMillionUSD: Double? = nil,
        textOutputPerMillionUSD: Double,
        sourceURL: String,
        verifiedOn: String,
        note: String? = nil
    ) {
        self.textInputPerMillionUSD = textInputPerMillionUSD
        self.audioInputPerMillionUSD = audioInputPerMillionUSD
        self.cachedTextInputPerMillionUSD = cachedTextInputPerMillionUSD
        self.cachedAudioInputPerMillionUSD = cachedAudioInputPerMillionUSD
        self.cacheWritePerMillionUSD = cacheWritePerMillionUSD
        self.textOutputPerMillionUSD = textOutputPerMillionUSD
        self.sourceURL = sourceURL
        self.verifiedOn = verifiedOn
        self.note = note
    }
}

public struct CostEstimate: Sendable, Equatable {
    public let approximateUSD: Double
    public let pricing: ModelPricing
}

public enum UsageCostCalculator {
    public static func estimate(_ usage: ProviderUsage, provider: AnswerProvider, pricing: ModelPricing?) -> CostEstimate? {
        guard let pricing, !usage.isEmpty else { return nil }
        let value: Double?
        switch provider {
        case .openAIRealtime: value = openAICost(usage, pricing)
        case .anthropicClaude: value = anthropicCost(usage, pricing)
        }
        guard let value else { return nil }
        return CostEstimate(approximateUSD: value, pricing: pricing)
    }

    private static func perMillion(_ tokens: Int, _ price: Double) -> Double {
        Double(tokens) / 1_000_000 * price
    }

    private static func openAICost(_ usage: ProviderUsage, _ pricing: ModelPricing) -> Double? {
        guard let inputText = usage.inputTextTokens, let inputAudio = usage.inputAudioTokens else { return nil }
        guard let output = usage.outputTextTokens ?? usage.outputTokens else { return nil }
        let cachedText = usage.cachedTextTokens ?? 0
        let cachedAudio = usage.cachedAudioTokens ?? 0
        if cachedText > 0, pricing.cachedTextInputPerMillionUSD == nil { return nil }
        if cachedAudio > 0, pricing.cachedAudioInputPerMillionUSD == nil { return nil }
        if inputAudio > 0, pricing.audioInputPerMillionUSD == nil { return nil }
        var total = perMillion(max(0, inputText - cachedText), pricing.textInputPerMillionUSD)
        total += perMillion(max(0, inputAudio - cachedAudio), pricing.audioInputPerMillionUSD ?? 0)
        total += perMillion(cachedText, pricing.cachedTextInputPerMillionUSD ?? 0)
        total += perMillion(cachedAudio, pricing.cachedAudioInputPerMillionUSD ?? 0)
        total += perMillion(output, pricing.textOutputPerMillionUSD)
        return total
    }

    private static func anthropicCost(_ usage: ProviderUsage, _ pricing: ModelPricing) -> Double? {
        guard let input = usage.inputTokens, let output = usage.outputTokens else { return nil }
        let cacheRead = usage.cachedInputTokens ?? 0
        let cacheWrite = usage.cacheCreationInputTokens ?? 0
        if cacheRead > 0, pricing.cachedTextInputPerMillionUSD == nil { return nil }
        if cacheWrite > 0, pricing.cacheWritePerMillionUSD == nil { return nil }
        var total = perMillion(input, pricing.textInputPerMillionUSD)
        total += perMillion(cacheRead, pricing.cachedTextInputPerMillionUSD ?? 0)
        total += perMillion(cacheWrite, pricing.cacheWritePerMillionUSD ?? 0)
        total += perMillion(output, pricing.textOutputPerMillionUSD)
        return total
    }
}
