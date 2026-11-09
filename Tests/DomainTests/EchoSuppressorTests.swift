import Foundation
import Testing
@testable import Domain

@Suite struct EchoSuppressorTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 10_000)

    @Test func loudSystemAudioClosesGateForItsDurationPlus300ms() {
        var echo = EchoSuppressor()
        #expect(echo.allowsOpening(at: t0))
        echo.noteSystemLevel(-20, at: t0)
        echo.noteSystemLevel(-25, at: t0.addingTimeInterval(0.1))
        #expect(!echo.allowsOpening(at: t0.addingTimeInterval(0.1)))
        #expect(!echo.allowsOpening(at: t0.addingTimeInterval(0.4)))
        #expect(echo.allowsOpening(at: t0.addingTimeInterval(0.41)))
    }

    @Test func quietSystemAudioDoesNotArmGate() {
        var echo = EchoSuppressor()
        echo.noteSystemLevel(-55, at: t0)
        echo.noteSystemLevel(-40.5, at: t0)
        #expect(echo.allowsOpening(at: t0))
        echo.noteSystemLevel(-40, at: t0)
        #expect(!echo.allowsOpening(at: t0))
    }

    @Test func lateOutOfOrderLevelDoesNotMoveGateBack() {
        var echo = EchoSuppressor()
        echo.noteSystemLevel(-10, at: t0.addingTimeInterval(1))
        echo.noteSystemLevel(-10, at: t0)
        #expect(!echo.allowsOpening(at: t0.addingTimeInterval(1.2)))
    }

    @Test func echoOfRemoteSentenceIsDuplicate() {
        var echo = EchoSuppressor()
        echo.noteRemoteTranscript(itemID: "them_1", text: "Расскажите, как вы проектировали платёжный сервис?", at: t0)
        #expect(echo.isEchoDuplicate("расскажите как вы проектировали платежный сервис", at: t0.addingTimeInterval(2)))
        #expect(!echo.isEchoDuplicate("Я проектировал его на Kafka и Postgres", at: t0.addingTimeInterval(2)))
    }

    @Test func englishPartialEchoAboveThresholdIsDuplicate() {
        var echo = EchoSuppressor()
        echo.noteRemoteTranscript(itemID: "them_1", text: "What is your experience with Swift concurrency?", at: t0)
        #expect(echo.isEchoDuplicate("your experience with Swift concurrency", at: t0.addingTimeInterval(1)))
        #expect(!echo.isEchoDuplicate("I have used Swift concurrency for three years", at: t0.addingTimeInterval(1)))
    }

    @Test func jaccardBoundaryIsInclusive() {
        let a = EchoSuppressor.tokens("one two three four five")
        let b = EchoSuppressor.tokens("one two three")
        #expect(EchoSuppressor.jaccard(a, b) == 0.6)
        var echo = EchoSuppressor()
        echo.noteRemoteTranscript(itemID: "x", text: "one two three four five", at: t0)
        #expect(echo.isEchoDuplicate("one two three", at: t0))
        #expect(!echo.isEchoDuplicate("one two", at: t0))
    }

    @Test func remoteTextOlderThanFiveSecondsIsForgotten() {
        var echo = EchoSuppressor()
        echo.noteRemoteTranscript(itemID: "them_1", text: "Tell me about yourself", at: t0)
        #expect(echo.isEchoDuplicate("tell me about yourself", at: t0.addingTimeInterval(5)))
        #expect(!echo.isEchoDuplicate("tell me about yourself", at: t0.addingTimeInterval(5.1)))
    }

    @Test func partialUpdatesReplaceTextForSameItem() {
        var echo = EchoSuppressor()
        echo.noteRemoteTranscript(itemID: "them_1", text: "Tell", at: t0)
        echo.noteRemoteTranscript(itemID: "them_1", text: "Tell me about your last project", at: t0.addingTimeInterval(0.5))
        #expect(echo.isEchoDuplicate("tell me about your last project", at: t0.addingTimeInterval(1)))
        #expect(!echo.isEchoDuplicate("tell", at: t0.addingTimeInterval(1)))
    }

    @Test func emptyOrPunctuationOnlyTextIsNeverDuplicate() {
        var echo = EchoSuppressor()
        echo.noteRemoteTranscript(itemID: "a", text: "…", at: t0)
        echo.noteRemoteTranscript(itemID: "b", text: "ok", at: t0)
        #expect(!echo.isEchoDuplicate("?!", at: t0))
        #expect(echo.isEchoDuplicate("OK.", at: t0))
    }

    @Test func resetClearsGateAndHistory() {
        var echo = EchoSuppressor()
        echo.noteSystemLevel(-5, at: t0)
        echo.noteRemoteTranscript(itemID: "a", text: "hello there", at: t0)
        echo.reset()
        #expect(echo.allowsOpening(at: t0))
        #expect(!echo.isEchoDuplicate("hello there", at: t0))
    }
}
