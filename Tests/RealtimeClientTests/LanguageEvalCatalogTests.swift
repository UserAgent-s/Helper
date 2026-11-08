import Foundation
import Testing

@Suite struct LanguageEvalCatalogTests {

    @Test func catalogHasNoDuplicateIDs() {
        let ids = LanguageEvalCatalog.cases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyCaseDeclaresExpectedLanguageAndNotes() {
        for evalCase in LanguageEvalCatalog.cases {
            #expect(!evalCase.expectedLanguage.isEmpty)
            #expect(!evalCase.notes.isEmpty)
            #expect(!evalCase.questionText.isEmpty)
        }
    }

    @Test func mixedCaseIsExplicitlySeparatedFromTheDeterministicCatalog() {
        #expect(LanguageEvalCatalog.mixedCase.expectedLanguage == "ru")
        #expect(!LanguageEvalCatalog.cases.contains { $0.id == LanguageEvalCatalog.mixedCase.id })
    }

    @Test func rubricFailsClosedWhenAnyDimensionFails() {
        var score = RubricScore(languageMatch: true, directness: true, technicalCorrectness: true, seniorJudgment: true, productionMindset: true, brevity: true)
        #expect(score.passed)
        score.languageMatch = false
        #expect(!score.passed)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_ASSISTANT_RUN_LIVE_EVALS"] == "1"))
    func liveModelRubricEval() async throws {
        Issue.record("Live model evals require OPENAI_API_KEY and a real LiveResponder pipeline; not implemented in this offline environment. Run manually with MEETING_ASSISTANT_RUN_LIVE_EVALS=1 once a live harness exists.")
    }
}
