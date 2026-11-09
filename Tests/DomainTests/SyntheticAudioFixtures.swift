import Foundation
@testable import Domain

enum SyntheticAudioFixtures {
    static func toneBurst(durationMs: Int, sampleRate: Int = 16_000, frequencyHz: Double = 440, amplitude: Double = 8000, source: AudioSourceKind = .systemAudio) -> [PCMAudioFrame] {
        let frameDurationMs = 20
        let frameCount = max(1, durationMs / frameDurationMs)
        let samplesPerFrame = sampleRate * frameDurationMs / 1000
        var frames: [PCMAudioFrame] = []
        var sampleIndex = 0
        let now = Date()
        for frameOffset in 0..<frameCount {
            var samples: [Int16] = []
            samples.reserveCapacity(samplesPerFrame)
            for _ in 0..<samplesPerFrame {
                let phase = Double(sampleIndex) / Double(sampleRate) * frequencyHz * 2 * .pi
                samples.append(Int16(sin(phase) * amplitude))
                sampleIndex += 1
            }
            frames.append(PCMAudioFrame(
                samples: samples,
                sampleRate: sampleRate,
                channelCount: 1,
                capturedAt: now.addingTimeInterval(Double(frameOffset * frameDurationMs) / 1000),
                source: source
            ))
        }
        return frames
    }

    static func silence(durationMs: Int, sampleRate: Int = 16_000, source: AudioSourceKind = .systemAudio) -> [PCMAudioFrame] {
        let frameDurationMs = 20
        let frameCount = max(1, durationMs / frameDurationMs)
        let samplesPerFrame = sampleRate * frameDurationMs / 1000
        let now = Date()
        return (0..<frameCount).map { frameOffset in
            PCMAudioFrame(
                samples: Array(repeating: 0, count: samplesPerFrame),
                sampleRate: sampleRate,
                channelCount: 1,
                capturedAt: now.addingTimeInterval(Double(frameOffset * frameDurationMs) / 1000),
                source: source
            )
        }
    }

    static func backgroundNoise(durationMs: Int, sampleRate: Int = 16_000, source: AudioSourceKind = .systemAudio) -> [PCMAudioFrame] {
        let frameDurationMs = 20
        let frameCount = max(1, durationMs / frameDurationMs)
        let samplesPerFrame = sampleRate * frameDurationMs / 1000
        let now = Date()
        var generator = SystemRandomNumberGenerator()
        return (0..<frameCount).map { frameOffset in
            let samples = (0..<samplesPerFrame).map { _ in Int16.random(in: -500...500, using: &generator) }
            return PCMAudioFrame(
                samples: samples,
                sampleRate: sampleRate,
                channelCount: 1,
                capturedAt: now.addingTimeInterval(Double(frameOffset * frameDurationMs) / 1000),
                source: source
            )
        }
    }

    static func explanationThenPauseThenQuestion(turnDurationsMs: [Int], pauseMs: Int) -> [PCMAudioFrame] {
        var frames: [PCMAudioFrame] = []
        for (index, duration) in turnDurationsMs.enumerated() {
            frames += toneBurst(durationMs: duration, frequencyHz: 300 + Double(index) * 50)
            if index < turnDurationsMs.count - 1 {
                frames += silence(durationMs: pauseMs)
            }
        }
        return frames
    }
}
