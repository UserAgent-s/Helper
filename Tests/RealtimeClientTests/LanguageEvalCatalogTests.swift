import Domain
import Foundation
import Testing
@testable import RealtimeClient

@Suite struct LanguageEvalCatalogTests {

    @Test func catalogHasNoDuplicateIDs() {
        let ids = LanguageEvalCatalog.cases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyCaseDeclaresExpectedLanguageAndNotes() {
        for evalCase in LanguageEvalCatalog.cases {
            #expect(!evalCase.expectedLanguage.isEmpty)
            #expect(!evalCase.notes.isEmpty)
            #expect(!evalCase.questionText.isEmpty || evalCase.expectsWaitSentinel)
        }
    }

    @Test func contextCasesCoverOwnerRemarksAndScreen() {
        let withContext = LanguageEvalCatalog.cases.filter { !$0.context.isEmpty }
        #expect(withContext.contains { $0.expectsWaitSentinel && $0.questionText.isEmpty })
        #expect(withContext.contains { $0.context.contains { if case .screen = $0 { true } else { false } } })
        #expect(withContext.contains { !$0.expectsWaitSentinel && $0.context.contains { if case .me = $0 { true } else { false } } })
        for evalCase in withContext {
            for context in evalCase.context {
                #expect(RealtimeInstructions.injectedItem(context)?.role == .user)
            }
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ASSISTANT_USERAGENT057_RUN_LIVE_EVALS"] == "1"))
    func liveModelRubricEval() async throws {
        Issue.record("Live model evals require OPENAI_API_KEY and a real LiveResponder pipeline; not implemented in this offline environment. Run manually with ASSISTANT_USERAGENT057_RUN_LIVE_EVALS=1 once a live harness exists.")
    }
}
