import Testing
@testable import Summary

@Suite struct CostEstimatorTests {

    @Test func estimateIsMarkedApproximate() {
        let estimate = CostEstimator.estimate(transcriptCharacterCount: 1000, modelID: SummaryModelCatalog.defaultModelID)
        #expect(estimate.isApproximate)
    }

    @Test func largerTranscriptsEstimateHigherCost() {
        let small = CostEstimator.estimate(transcriptCharacterCount: 1000, modelID: SummaryModelCatalog.defaultModelID)
        let large = CostEstimator.estimate(transcriptCharacterCount: 100_000, modelID: SummaryModelCatalog.defaultModelID)
        #expect(large.estimatedCostUSD > small.estimatedCostUSD)
    }

    @Test func economyModelIsCheaperThanDefaultForSameInput() {
        let defaultCost = CostEstimator.estimate(transcriptCharacterCount: 10_000, modelID: SummaryModelCatalog.defaultModelID)
        let economyCost = CostEstimator.estimate(transcriptCharacterCount: 10_000, modelID: SummaryModelCatalog.economyModelID)
        #expect(economyCost.estimatedCostUSD < defaultCost.estimatedCostUSD)
    }
}
