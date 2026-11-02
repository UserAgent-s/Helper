public struct AnswerModelDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let provider: AnswerProvider
    public let displayName: String
    public let pricing: ModelPricing?
    public let supportsReasoningEffort: Bool
    public let supportsServerSideFallback: Bool
    public let note: String?

    public init(
        id: String,
        provider: AnswerProvider,
        displayName: String,
        pricing: ModelPricing?,
        supportsReasoningEffort: Bool,
        supportsServerSideFallback: Bool = false,
        note: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.pricing = pricing
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsServerSideFallback = supportsServerSideFallback
        self.note = note
    }
}

public enum AnswerModelCatalog {
    public static let openAIPricingSource = "https://developers.openai.com/api/docs/pricing"
    public static let openAIVerifiedOn = "2026-10-15"
    public static let anthropicPricingSource = "https://platform.claude.com/docs/en/about-claude/pricing"
    public static let anthropicVerifiedOn = "2026-10-06"

    public static let defaultOpenAIModelID = "gpt-realtime-2.1"
    public static let defaultAnthropicModelID = "claude-opus-5-5"

    private static func realtime(audioIn: Double, audioCached: Double, textIn: Double, textCached: Double, textOut: Double) -> ModelPricing {
        ModelPricing(
            textInputPerMillionUSD: textIn,
            audioInputPerMillionUSD: audioIn,
            cachedTextInputPerMillionUSD: textCached,
            cachedAudioInputPerMillionUSD: audioCached,
            textOutputPerMillionUSD: textOut,
            sourceURL: openAIPricingSource,
            verifiedOn: openAIVerifiedOn
        )
    }

    private static func claude(input: Double, cacheRead: Double, output: Double, note: String? = nil) -> ModelPricing {
        ModelPricing(
            textInputPerMillionUSD: input,
            cachedTextInputPerMillionUSD: cacheRead,
            cacheWritePerMillionUSD: input * 1.25,
            textOutputPerMillionUSD: output,
            sourceURL: anthropicPricingSource,
            verifiedOn: anthropicVerifiedOn,
            note: note
        )
    }

    public static let openAIModels: [AnswerModelDescriptor] = [
        AnswerModelDescriptor(
            id: "gpt-realtime-2.1",
            provider: .openAIRealtime,
            displayName: "gpt-realtime-2.1",
            pricing: realtime(audioIn: 32, audioCached: 0.40, textIn: 4, textCached: 0.40, textOut: 24),
            supportsReasoningEffort: true
        ),
        AnswerModelDescriptor(
            id: "gpt-realtime-2.1-mini",
            provider: .openAIRealtime,
            displayName: "gpt-realtime-2.1-mini",
            pricing: realtime(audioIn: 10, audioCached: 0.30, textIn: 0.60, textCached: 0.06, textOut: 2.40),
            supportsReasoningEffort: false
        ),
        AnswerModelDescriptor(
            id: "gpt-realtime-2",
            provider: .openAIRealtime,
            displayName: "gpt-realtime-2",
            pricing: realtime(audioIn: 32, audioCached: 0.40, textIn: 4, textCached: 0.40, textOut: 24),
            supportsReasoningEffort: true
        ),
        AnswerModelDescriptor(
            id: "gpt-realtime-mini",
            provider: .openAIRealtime,
            displayName: "gpt-realtime-mini",
            pricing: realtime(audioIn: 10, audioCached: 0.30, textIn: 0.60, textCached: 0.06, textOut: 2.40),
            supportsReasoningEffort: false
        ),
    ]

    public static let anthropicModels: [AnswerModelDescriptor] = [
        AnswerModelDescriptor(
            id: "claude-opus-5-5",
            provider: .anthropicClaude,
            displayName: "Claude Opus 5.5",
            pricing: claude(input: 4, cacheRead: 0.20, output: 20),
            supportsReasoningEffort: true,
            supportsServerSideFallback: true
        ),
        AnswerModelDescriptor(
            id: "claude-sonnet-5-5",
            provider: .anthropicClaude,
            displayName: "Claude Sonnet 5.5",
            pricing: claude(input: 2, cacheRead: 0.20, output: 10),
            supportsReasoningEffort: true,
            supportsServerSideFallback: true
        ),
        AnswerModelDescriptor(
            id: "claude-haiku-5-5",
            provider: .anthropicClaude,
            displayName: "Claude Haiku 5.5",
            pricing: claude(input: 0.10, cacheRead: 0.01, output: 0.50, note: "prompt <= 100K tokens; cache read = 0.1x input"),
            supportsReasoningEffort: true
        ),
        AnswerModelDescriptor(
            id: "claude-fable-5-1",
            provider: .anthropicClaude,
            displayName: "Claude Fable 5.1",
            pricing: claude(input: 10, cacheRead: 0.25, output: 50),
            supportsReasoningEffort: true,
            note: "requires 30-day data retention on the Anthropic organization"
        ),
    ]

    public static func models(for provider: AnswerProvider) -> [AnswerModelDescriptor] {
        switch provider {
        case .openAIRealtime: openAIModels
        case .anthropicClaude: anthropicModels
        }
    }

    public static func defaultModelID(for provider: AnswerProvider) -> String {
        switch provider {
        case .openAIRealtime: defaultOpenAIModelID
        case .anthropicClaude: defaultAnthropicModelID
        }
    }

    public static func descriptor(provider: AnswerProvider, modelID: String) -> AnswerModelDescriptor? {
        models(for: provider).first { $0.id == modelID }
    }
}
