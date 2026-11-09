import Foundation
import Testing
@testable import Domain

@Suite struct ClientVADTests {
    private func turns(_ events: [ClientVADEvent]) -> Int {
        events.filter { $0 == .opened }.count
    }

    private func closes(_ events: [ClientVADEvent]) -> [ClientVADEvent] {
        events.filter { if case .closed = $0 { true } else { false } }
    }

    @Test func russianPhraseWithWordPausesIsOneTurnCommittedAfterSilence() {
        var vad = ClientVoiceActivityDetector()
        let segments = [.gap(ms: 400)] + MeSpeechFixture.russianQuestionAnswer + [.gap(ms: 900)]
        let events = vad.run(MeSpeechFixture(segments: segments).frames())
        #expect(events.first == .opened)
        #expect(turns(events) == 1)
        #expect(closes(events).count == 1)
        guard case .closed(let duration, let forced) = events.last else {
            Issue.record("expected close, got \(events)")
            return
        }
        #expect(!forced)
        #expect(duration >= 2_000)
        #expect(!vad.isOpen)
    }

    @Test func englishPhraseIsOneTurn() {
        var vad = ClientVoiceActivityDetector()
        let segments = [.gap(ms: 300)] + MeSpeechFixture.englishAnswer + [.gap(ms: 800)]
        let events = vad.run(MeSpeechFixture(segments: segments).frames())
        #expect(events.count == 2)
        #expect(events.first == .opened)
    }

    @Test func longPauseSplitsIntoTwoTurns() {
        var vad = ClientVoiceActivityDetector()
        let segments = MeSpeechFixture.englishAnswer + [.gap(ms: 1_200)] + MeSpeechFixture.russianQuestionAnswer + [.gap(ms: 800)]
        let events = vad.run(MeSpeechFixture(segments: segments).frames())
        #expect(turns(events) == 2)
        #expect(closes(events).count == 2)
    }

    @Test func pauseShorterThanHangoverKeepsTurnOpen() {
        var vad = ClientVoiceActivityDetector()
        let segments = MeSpeechFixture.englishAnswer + [.gap(ms: 450)] + MeSpeechFixture.englishAnswer + [.gap(ms: 800)]
        let events = vad.run(MeSpeechFixture(segments: segments).frames())
        #expect(turns(events) == 1)
        #expect(closes(events).count == 1)
    }

    @Test func backgroundNoiseAloneNeverOpens() {
        var vad = ClientVoiceActivityDetector()
        let fixture = MeSpeechFixture(segments: [.gap(ms: 5_000)], noiseAmplitude: 100)
        let events = vad.run(fixture.frames())
        #expect(events.isEmpty)
        #expect(vad.noiseFloorDBFS > -60)
        #expect(vad.noiseFloorDBFS < -50)
    }

    @Test func speechOverBackgroundNoiseStillOpensAndCloses() {
        var vad = ClientVoiceActivityDetector()
        let segments = [.gap(ms: 1_000)] + MeSpeechFixture.russianQuestionAnswer + [.gap(ms: 1_000)]
        let events = vad.run(MeSpeechFixture(segments: segments, noiseAmplitude: 100).frames())
        #expect(turns(events) == 1)
        #expect(closes(events).count == 1)
    }

    @Test func shortClickDoesNotOpen() {
        var vad = ClientVoiceActivityDetector()
        let events = vad.run(MeSpeechFixture(segments: [.gap(ms: 200), .syllable(ms: 40, amplitude: 9_000), .gap(ms: 800)]).frames())
        #expect(events.isEmpty)
    }

    @Test func quietMumbleBelowAbsoluteThresholdDoesNotOpen() {
        var vad = ClientVoiceActivityDetector()
        let events = vad.run(MeSpeechFixture(segments: MeSpeechFixture.englishAnswer.map {
            if case .syllable(let ms, _) = $0 { .syllable(ms: ms, amplitude: 120) } else { $0 }
        }).frames())
        #expect(events.isEmpty)
    }

    @Test func monologueLongerThanMaxTurnIsForceCommitted() {
        var vad = ClientVoiceActivityDetector(configuration: ClientVADConfiguration(maxTurnMs: 2_000))
        let segments = Array(repeating: MeSpeechFixture.russianQuestionAnswer, count: 3).flatMap { $0 + [.gap(ms: 100)] }
        let events = vad.run(MeSpeechFixture(segments: segments).frames())
        #expect(events.contains { if case .closed(_, true) = $0 { true } else { false } })
        #expect(turns(events) >= 2)
    }

    @Test func gateBlocksOpeningButNeverCutsAnOpenTurn() {
        let frames = MeSpeechFixture(segments: MeSpeechFixture.englishAnswer + [.gap(ms: 800)]).frames()
        var blocked = ClientVoiceActivityDetector()
        let blockedEvents = blocked.run(frames) { _ in false }
        #expect(blockedEvents.isEmpty)

        var interrupted = ClientVoiceActivityDetector()
        let gateFrom = frames[frames.count / 3].capturedAt
        let events = interrupted.run(frames) { $0.capturedAt < gateFrom }
        #expect(events.first == .opened)
        #expect(closes(events).count == 1)
    }

    @Test func interruptionAfterGateLiftsOpensLateTurn() {
        let frames = MeSpeechFixture(segments: MeSpeechFixture.russianQuestionAnswer + [.gap(ms: 800)]).frames()
        let liftAt = frames[frames.count / 2].capturedAt
        var vad = ClientVoiceActivityDetector()
        let events = vad.run(frames) { $0.capturedAt >= liftAt }
        #expect(turns(events) == 1)
    }

    @Test func arbitraryFrameSizesGiveSameDecisions() {
        let fixture = MeSpeechFixture(segments: [.gap(ms: 300)] + MeSpeechFixture.englishAnswer + [.gap(ms: 900)])
        var reference = ClientVoiceActivityDetector()
        let expected = reference.run(fixture.frames())
        var odd = fixture
        odd.frameMs = 7
        var vad = ClientVoiceActivityDetector()
        let actual = vad.run(odd.frames())
        #expect(actual.map { if case .closed = $0 { "closed" } else { "opened" } } == expected.map { if case .closed = $0 { "closed" } else { "opened" } })
    }

    @Test func resetForgetsOpenTurn() {
        var vad = ClientVoiceActivityDetector()
        _ = vad.run(MeSpeechFixture(segments: MeSpeechFixture.englishAnswer).frames())
        #expect(vad.isOpen)
        vad.reset()
        #expect(!vad.isOpen)
        #expect(vad.noiseFloorDBFS == ClientVADConfiguration().initialNoiseFloorDBFS)
    }
}
