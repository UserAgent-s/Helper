import Domain
import Foundation
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

@Suite struct InstructionProfileTests {
    private func golden(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test(arguments: AnswerLength.allCases)
    func interviewProfileIsByteIdenticalToVersion6(length: AnswerLength) throws {
        let expected = try golden("instructions-v6-\(length.rawValue)")
        #expect(RealtimeInstructions.system(for: length, profile: .interviewFirstPerson) == expected)
        #expect(RealtimeInstructions.system(for: length) == expected)
    }

    @Test func interviewWithBackgroundMatchesGolden() throws {
        #expect(RealtimeInstructions.system(for: .standard, profile: .interviewFirstPerson, background: "BACKGROUND_PLACEHOLDER") == (try golden("instructions-v6-standard-background")))
    }

    @Test func interviewSectionsAreFoundVerbatimSoBilingualReplacementApplies() {
        let base = RealtimeInstructions.base(for: .interviewFirstPerson)
        #expect(base.contains(RealtimeInstructions.interviewLanguageSection))
        #expect(base.contains(RealtimeInstructions.interviewExamplesHeading))
    }

    @Test(arguments: AnswerLength.allCases)
    func bilingualAllowsRussianPlusEnglishPhrase(length: AnswerLength) {
        let text = RealtimeInstructions.system(for: length, profile: .bilingualAssist, background: "PHP")
        #expect(!text.contains("Do not translate"))
        #expect(!text.contains("always answer in the question's own language"))
        #expect(text.contains("Write the main answer in Russian"))
        #expect(text.contains("`EN:`"))
        #expect(text.contains("⟦WAIT_FOR_QUESTION⟧"))
        #expect(text.contains("# Candidate background"))
        #expect(text.contains("# Format"))
    }

    @Test func profilesDifferOnlyInLanguageRules() {
        let interview = RealtimeInstructions.system(for: .standard, profile: .interviewFirstPerson)
        let bilingual = RealtimeInstructions.system(for: .standard, profile: .bilingualAssist)
        #expect(interview != bilingual)
        let strip: (String) -> String = { text in
            text.replacingOccurrences(of: RealtimeInstructions.interviewLanguageSection, with: "")
                .replacingOccurrences(of: RealtimeInstructions.bilingualLanguageSection, with: "")
                .replacingOccurrences(of: RealtimeInstructions.interviewExamplesHeading, with: "")
                .replacingOccurrences(of: RealtimeInstructions.bilingualExamplesHeading, with: "")
        }
        #expect(strip(interview) == strip(bilingual))
    }
}
