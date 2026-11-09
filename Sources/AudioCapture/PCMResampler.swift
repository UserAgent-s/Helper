import Domain

public enum PCMResampler {
    public static func downmixToMono(samples: [Int16], channelCount: Int) -> [Int16] {
        guard channelCount > 1 else { return samples }
        var mono = [Int16]()
        mono.reserveCapacity(samples.count / channelCount)
        var i = 0
        while i + channelCount <= samples.count {
            var sum = 0
            for c in 0..<channelCount { sum += Int(samples[i + c]) }
            mono.append(Int16(clamping: sum / channelCount))
            i += channelCount
        }
        return mono
    }

    public static func resample(monoSamples: [Int16], fromRate: Int, toRate: Int) -> [Int16] {
        guard fromRate != toRate, !monoSamples.isEmpty, fromRate > 0, toRate > 0 else {
            return monoSamples
        }
        let ratio = Double(toRate) / Double(fromRate)
        let outputCount = Int((Double(monoSamples.count) * ratio).rounded())
        guard outputCount > 0 else { return [] }

        var output = [Int16](repeating: 0, count: outputCount)
        let step = Double(fromRate) / Double(toRate)
        let lastIndex = monoSamples.count - 1

        for i in 0..<outputCount {
            let srcPosition = Double(i) * step
            let srcIndex = min(Int(srcPosition), lastIndex)
            let frac = srcPosition - Double(srcIndex)
            let s0 = monoSamples[srcIndex]
            let s1 = monoSamples[min(srcIndex + 1, lastIndex)]
            let interpolated = Double(s0) + (Double(s1) - Double(s0)) * frac
            output[i] = Int16(clamping: Int(interpolated.rounded()))
        }
        return output
    }
}

public struct RealtimeAudioFormatConverter: Sendable {
    public static let targetSampleRate = 24_000
    public static let frameDurationMs = 20
    public static var samplesPerFrame: Int { targetSampleRate * frameDurationMs / 1000 }

    private var carry: [Int16] = []

    public init() {}

    public mutating func convert(_ frame: PCMAudioFrame) -> [PCMAudioFrame] {
        let mono = PCMResampler.downmixToMono(samples: frame.samples, channelCount: frame.channelCount)
        let resampled = PCMResampler.resample(monoSamples: mono, fromRate: frame.sampleRate, toRate: Self.targetSampleRate)
        carry.append(contentsOf: resampled)

        var output: [PCMAudioFrame] = []
        let perFrame = Self.samplesPerFrame
        while carry.count >= perFrame {
            let chunk = Array(carry.prefix(perFrame))
            carry.removeFirst(perFrame)
            output.append(PCMAudioFrame(
                samples: chunk,
                sampleRate: Self.targetSampleRate,
                channelCount: 1,
                capturedAt: frame.capturedAt,
                source: frame.source
            ))
        }
        return output
    }
}

public enum WhisperAudioFormatConverter {
    public static let targetSampleRate = 16_000

    public static func convert(_ frame: PCMAudioFrame) -> PCMAudioFrame {
        let mono = PCMResampler.downmixToMono(samples: frame.samples, channelCount: frame.channelCount)
        let resampled = PCMResampler.resample(monoSamples: mono, fromRate: frame.sampleRate, toRate: targetSampleRate)
        return PCMAudioFrame(
            samples: resampled,
            sampleRate: targetSampleRate,
            channelCount: 1,
            capturedAt: frame.capturedAt,
            source: frame.source
        )
    }
}

public struct WhisperFrameConverter: AudioFormatConverting {
    public init() {}

    public func convert(_ frame: PCMAudioFrame) -> PCMAudioFrame {
        WhisperAudioFormatConverter.convert(frame)
    }
}
