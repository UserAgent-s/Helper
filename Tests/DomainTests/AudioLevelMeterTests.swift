import Foundation
import Testing
@testable import Domain

@Suite struct AudioLevelMeterTests {

    @Test func halfScaleToneMeasuresMinusSixPeak() {
        var meter = AudioLevelMeter()
        let levels = SyntheticAudioFixtures.toneBurst(durationMs: 1000, sampleRate: 24_000, frequencyHz: 1000, amplitude: 16_384)
            .compactMap { meter.ingest($0) }
        let level = try! #require(levels.last)
        #expect(abs(level.peakDBFS - -6.02) <= 0.5)
        #expect(abs(level.rmsDBFS - -9.03) <= 0.5)
        #expect(level.kind == .systemAudio)
    }

    @Test func silenceIsBelowMinusNinety() {
        var meter = AudioLevelMeter()
        let levels = SyntheticAudioFixtures.silence(durationMs: 500, sampleRate: 24_000).compactMap { meter.ingest($0) }
        #expect(!levels.isEmpty)
        #expect(levels.allSatisfy { $0.rmsDBFS <= -90 && $0.peakDBFS <= -90 })
    }

    @Test func emitsTenLevelsPerSecondOfAudio() {
        var meter = AudioLevelMeter()
        let levels = SyntheticAudioFixtures.backgroundNoise(durationMs: 1000, sampleRate: 24_000).compactMap { meter.ingest($0) }
        #expect(levels.count == 10)
    }
}
