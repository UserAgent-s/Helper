import Testing
@testable import ClaudeClient

@Suite struct ClaudeCostEstimatorTests {
    @Test func sonnetWithOneHourCacheWriteThenRead() {
        let first = ClaudeUsage(inputTokens: 200, outputTokens: 1_000, cacheCreationInputTokens: 25_000, cacheReadInputTokens: 0, cacheCreation5mTokens: 0, cacheCreation1hTokens: 25_000)
        let cost = ClaudeCostEstimator.estimate(first, model: .sonnet)
        #expect(abs(cost.input - 0.0004) < 1e-9)
        #expect(abs(cost.cacheWrite - 0.1) < 1e-9)
        #expect(abs(cost.output - 0.01) < 1e-9)
        #expect(abs(cost.total - 0.1104) < 1e-9)

        let second = ClaudeUsage(inputTokens: 200, outputTokens: 1_000, cacheReadInputTokens: 25_000)
        let warm = ClaudeCostEstimator.estimate(second, model: .sonnet)
        #expect(abs(warm.cacheRead - 0.005) < 1e-9)
        #expect(warm.cacheWrite == 0)
        #expect(warm.total < cost.total / 5)
    }

    @Test func fiveMinuteWriteWithoutBreakdownUses125x() {
        let usage = ClaudeUsage(cacheCreationInputTokens: 1_000_000)
        #expect(abs(ClaudeCostEstimator.estimate(usage, model: .opus).cacheWrite - 5.0) < 1e-9)
    }

    @Test func haikuLongContextTier() {
        let small = ClaudeCostEstimator.estimate(ClaudeUsage(inputTokens: 100_000, outputTokens: 1_000_000), model: .haiku)
        #expect(abs(small.input - 0.01) < 1e-9)
        #expect(abs(small.output - 0.5) < 1e-9)
        let large = ClaudeCostEstimator.estimate(ClaudeUsage(inputTokens: 100_001, outputTokens: 1_000_000), model: .haiku)
        #expect(abs(large.output - 2.5) < 1e-9)
        #expect(abs(large.input - 100_001 * 0.5 / 1_000_000) < 1e-12)
    }

    @Test func catalogIDsAndFallbackSupport() {
        #expect(ClaudeModel.allCases.map(\.rawValue) == ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"])
        #expect(ClaudeModelCatalog.info(.sonnet).supportsServerFallback)
        #expect(ClaudeModelCatalog.info(.opus).supportsServerFallback)
        #expect(!ClaudeModelCatalog.info(.haiku).supportsServerFallback)
        #expect(ClaudeModelCatalog.info(modelID: "claude-sonnet-5") == nil)
        #expect(ClaudeModelCatalog.apiVersion == "2026-10-21")
    }
}
