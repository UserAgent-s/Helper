import Foundation
@testable import Domain

struct MeSpeechFixture {
    enum Segment {
        case syllable(ms: Int, amplitude: Double)
        case gap(ms: Int)
    }

    var segments: [Segment]
    var noiseAmplitude: Double = 0
    var sampleRate = 24_000
    var frameMs = 20
    var start = Date(timeIntervalSinceReferenceDate: 1_000)
    var seed: UInt64 = 57

    static func phrase(syllables: [Int], wordGapMs: Int, wordsOf size: Int, amplitude: Double = 6_000) -> [Segment] {
        var result: [Segment] = []
        for (index, duration) in syllables.enumerated() {
            result.append(.syllable(ms: duration, amplitude: amplitude))
            if index < syllables.count - 1 {
                result.append(.gap(ms: (index + 1) % size == 0 ? wordGapMs : 30))
            }
        }
        return result
    }

    static let russianQuestionAnswer = phrase(syllables: [140, 120, 180, 110, 160, 130, 150, 120, 200, 140, 170], wordGapMs: 160, wordsOf: 3)
    static let englishAnswer = phrase(syllables: [180, 200, 150, 220, 170, 190, 160, 240], wordGapMs: 220, wordsOf: 2)

    func frames() -> [PCMAudioFrame] {
        var samples: [Int16] = []
        var rng = seed
        var index = 0
        func noise() -> Double {
            guard noiseAmplitude > 0 else { return 0 }
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(rng >> 11) / Double(1 << 53)
            return (unit * 2 - 1) * noiseAmplitude
        }
        for segment in segments {
            switch segment {
            case .gap(let ms):
                for _ in 0..<(sampleRate * ms / 1000) {
                    samples.append(Int16(clamping: Int(noise())))
                    index += 1
                }
            case .syllable(let ms, let amplitude):
                let count = sampleRate * ms / 1000
                for n in 0..<count {
                    let envelope = 0.3 + 0.7 * sin(Double(n) / Double(count) * .pi)
                    let phase = Double(index) / Double(sampleRate) * 2 * .pi
                    let voiced = sin(phase * 180) * 0.6 + sin(phase * 720) * 0.3 + sin(phase * 1_440) * 0.1
                    samples.append(Int16(clamping: Int(voiced * amplitude * envelope + noise())))
                    index += 1
                }
            }
        }
        let perFrame = sampleRate * frameMs / 1000
        var frames: [PCMAudioFrame] = []
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + perFrame)
            frames.append(PCMAudioFrame(
                samples: Array(samples[offset..<end]),
                sampleRate: sampleRate,
                channelCount: 1,
                capturedAt: start.addingTimeInterval(Double(offset) / Double(sampleRate)),
                source: .microphone
            ))
            offset = end
        }
        return frames
    }
}

extension ClientVoiceActivityDetector {
    mutating func run(_ frames: [PCMAudioFrame], openingAllowed: (PCMAudioFrame) -> Bool = { _ in true }) -> [ClientVADEvent] {
        frames.flatMap { ingest($0, openingAllowed: openingAllowed($0)) }
    }
}
