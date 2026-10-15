import Testing
import WhisperKit
@testable import Transcription

@Suite struct WhisperKitTranscribingTests {

    @Test func nonSpeechAnnotationsAreDetected() {
        #expect(WhisperKitTranscribing.isNonSpeechAnnotation("(kissing)"))
        #expect(WhisperKitTranscribing.isNonSpeechAnnotation("(cat meows)"))
        #expect(WhisperKitTranscribing.isNonSpeechAnnotation("[no audio]"))
        #expect(WhisperKitTranscribing.isNonSpeechAnnotation("[ ]"))
        #expect(WhisperKitTranscribing.isNonSpeechAnnotation("[BLANK_AUDIO]"))
    }

    @Test func realSpeechIsNotFlaggedAsAnnotation() {
        #expect(!WhisperKitTranscribing.isNonSpeechAnnotation("What is PHP?"))
        #expect(!WhisperKitTranscribing.isNonSpeechAnnotation("They are defined in the files of route, such as PHP and API."))
        #expect(!WhisperKitTranscribing.isNonSpeechAnnotation("I would use Laravel (a PHP framework) here."))
    }

    @Test func segmentWithHighNoSpeechProbAndLowConfidenceIsHallucinated() {
        let segment = TranscriptionSegment(text: "(growling)", avgLogprob: -1.5, compressionRatio: 1.0, noSpeechProb: 0.9)
        #expect(WhisperKitTranscribing.isLikelyHallucinated(segment))
    }

    @Test func segmentWithHighCompressionRatioIsHallucinated() {
        let segment = TranscriptionSegment(text: "the the the the the the", avgLogprob: -0.1, compressionRatio: 3.0, noSpeechProb: 0.1)
        #expect(WhisperKitTranscribing.isLikelyHallucinated(segment))
    }

    @Test func confidentSegmentIsNotFlaggedAsHallucinated() {
        let segment = TranscriptionSegment(text: "What is PHP?", avgLogprob: -0.2, compressionRatio: 1.2, noSpeechProb: 0.05)
        #expect(!WhisperKitTranscribing.isLikelyHallucinated(segment))
    }

    @Test func stripsLeadingSpecialTokens() {
        let input = "<|startoftranscript|><|en|><|transcribe|><|0.00|> The most popular PHP frameworks in the world today."
        #expect(WhisperKitTranscribing.stripSpecialTokens(input) == " The most popular PHP frameworks in the world today.")
    }

    @Test func stripsMultipleConcatenatedSegmentMarkers() {
        let input = "<|startoftranscript|><|en|><|transcribe|><|0.00|> First question.<|13.76|> <|startoftranscript|><|en|><|transcribe|><|0.00|> Second question.<|3.16|><|endoftext|>"
        #expect(WhisperKitTranscribing.stripSpecialTokens(input) == " First question.  Second question.")
    }

    @Test func leavesPlainTextUnchanged() {
        #expect(WhisperKitTranscribing.stripSpecialTokens("What is PHP?") == "What is PHP?")
    }

    @Test func leavesTextWithoutClosingMarkerUnchanged() {
        #expect(WhisperKitTranscribing.stripSpecialTokens("a <| b") == "a <| b")
    }
}
