import Domain
import Testing
@testable import RealtimeClient

@Suite struct RealtimeInstructionsTests {

    @Test func allLengthsProduceTwoParagraphGuidanceExceptShort() {
        #expect(!RealtimeInstructions.system(for: .short).contains("Write exactly two"))
        #expect(RealtimeInstructions.system(for: .standard).contains("Write exactly two short paragraphs"))
        #expect(RealtimeInstructions.system(for: .detailed).contains("Write exactly two paragraphs"))
    }

    @Test func wordBudgetsIncreaseWithLength() {
        #expect(RealtimeInstructions.system(for: .short).contains("40 words"))
        #expect(RealtimeInstructions.system(for: .standard).contains("120 words"))
        #expect(RealtimeInstructions.system(for: .detailed).contains("220 words"))
    }

    @Test func allLengthsShareTheSameBaseRules() {
        for length in AnswerLength.allCases {
            let text = RealtimeInstructions.system(for: length)
            #expect(text.contains("⟦WAIT_FOR_QUESTION⟧"))
            #expect(text.contains("Never answer with a counter-question"))
        }
    }

    @Test func emptyBackgroundOmitsCandidateBackgroundSection() {
        #expect(!RealtimeInstructions.system(for: .standard).contains("# Candidate background"))
        #expect(!RealtimeInstructions.system(for: .standard, background: "   ").contains("# Candidate background"))
    }

    @Test func nonEmptyBackgroundIsIncludedVerbatim() {
        let text = RealtimeInstructions.system(for: .standard, background: "10+ years PHP, Laravel, Symfony.")
        #expect(text.contains("# Candidate background"))
        #expect(text.contains("10+ years PHP, Laravel, Symfony."))
        #expect(text.contains("never bluff"))
    }

    @Test func formatOverridesCoverComparisonCodingAndUnfamiliarTech() {
        let text = RealtimeInstructions.system(for: .standard)
        #expect(text.contains("# Format overrides"))
        #expect(text.contains("haven't worked with X commercially"))
    }
}
