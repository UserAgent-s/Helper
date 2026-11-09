import Foundation

public struct AudioLevel: Sendable, Equatable {
    public let kind: AudioSourceKind
    public let rmsDBFS: Float
    public let peakDBFS: Float
    public let at: Date

    public init(kind: AudioSourceKind, rmsDBFS: Float, peakDBFS: Float, at: Date) {
        self.kind = kind
        self.rmsDBFS = rmsDBFS
        self.peakDBFS = peakDBFS
        self.at = at
    }
}

public struct AudioLevelMeter: Sendable {
    public static let floorDBFS: Float = -120

    private let windowMs: Int
    private var sumOfSquares: Double = 0
    private var peak: Int32 = 0
    private var sampleCount = 0

    public init(windowMs: Int = 100) {
        self.windowMs = max(1, windowMs)
    }

    public mutating func ingest(_ frame: PCMAudioFrame) -> AudioLevel? {
        guard frame.sampleRate > 0 else { return nil }
        for sample in frame.samples {
            let value = Int32(sample)
            sumOfSquares += Double(value * value)
            peak = max(peak, abs(value))
        }
        sampleCount += frame.samples.count / max(1, frame.channelCount)
        let windowSamples = frame.sampleRate * windowMs / 1000
        guard sampleCount >= windowSamples else { return nil }
        let totalSamples = max(1, sampleCount * max(1, frame.channelCount))
        let rms = (sumOfSquares / Double(totalSamples)).squareRoot()
        let level = AudioLevel(
            kind: frame.source,
            rmsDBFS: Self.dbfs(rms),
            peakDBFS: Self.dbfs(Double(peak)),
            at: frame.capturedAt
        )
        sumOfSquares = 0
        peak = 0
        sampleCount = 0
        return level
    }

    static func dbfs(_ amplitude: Double) -> Float {
        guard amplitude > 0 else { return floorDBFS }
        return max(floorDBFS, Float(20 * log10(amplitude / 32768)))
    }
}
