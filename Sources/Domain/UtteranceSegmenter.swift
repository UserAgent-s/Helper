import Foundation

public struct SpeechUtterance: Sendable, Equatable {
    public enum EndReason: Sendable, Equatable {
        case pause
        case maxDuration
        case forced
    }

    public let frames: [PCMAudioFrame]
    public let endReason: EndReason
    public let overlapsPrevious: Bool
    public let closedAt: Date

    public var durationMs: Double {
        frames.reduce(0) { $0 + UtteranceSegmenter.durationMs(of: $1) }
    }
}

public struct UtteranceSegmenterConfiguration: Sendable, Equatable {
    public var minimumSpeechRMS: Double
    public var noiseFloorMultiplier: Double
    public var pauseToCloseMs: Double
    public var minimumSpeechMs: Double
    public var maximumUtteranceMs: Double
    public var overlapMs: Double
    public var preRollMs: Double

    public init(
        minimumSpeechRMS: Double = 0.012,
        noiseFloorMultiplier: Double = 3,
        pauseToCloseMs: Double = 700,
        minimumSpeechMs: Double = 250,
        maximumUtteranceMs: Double = 12_000,
        overlapMs: Double = 1_000,
        preRollMs: Double = 300
    ) {
        self.minimumSpeechRMS = minimumSpeechRMS
        self.noiseFloorMultiplier = noiseFloorMultiplier
        self.pauseToCloseMs = pauseToCloseMs
        self.minimumSpeechMs = minimumSpeechMs
        self.maximumUtteranceMs = maximumUtteranceMs
        self.overlapMs = overlapMs
        self.preRollMs = preRollMs
    }

    public static let `default` = UtteranceSegmenterConfiguration()
}

public struct UtteranceSegmenter: Sendable {
    public let configuration: UtteranceSegmenterConfiguration
    private var preRoll: [PCMAudioFrame] = []
    private var preRollMs: Double = 0
    private var current: [PCMAudioFrame] = []
    private var currentMs: Double = 0
    private var speechMs: Double = 0
    private var trailingSilenceMs: Double = 0
    private var inSpeech = false
    private var currentOverlapsPrevious = false
    private var noiseFloor: Double = 0.003

    public init(configuration: UtteranceSegmenterConfiguration = .default) {
        self.configuration = configuration
    }

    public var bufferedDurationMs: Double {
        currentMs + preRollMs
    }

    public var hasPendingSpeech: Bool {
        inSpeech && speechMs >= configuration.minimumSpeechMs
    }

    public mutating func reset() {
        self = UtteranceSegmenter(configuration: configuration)
    }

    public mutating func ingest(_ frame: PCMAudioFrame, now: Date = Date()) -> [SpeechUtterance] {
        let frameMs = Self.durationMs(of: frame)
        guard frameMs > 0 else { return [] }
        let rms = Self.rms(of: frame)
        let threshold = max(configuration.minimumSpeechRMS, noiseFloor * configuration.noiseFloorMultiplier)
        let isSpeech = rms >= threshold

        if !isSpeech {
            noiseFloor = noiseFloor * 0.95 + rms * 0.05
        }

        guard inSpeech else {
            if isSpeech {
                inSpeech = true
                current = preRoll
                currentMs = preRollMs
                preRoll = []
                preRollMs = 0
                speechMs = frameMs
                trailingSilenceMs = 0
                append(frame, ms: frameMs)
            } else {
                pushPreRoll(frame, ms: frameMs)
            }
            return []
        }

        append(frame, ms: frameMs)
        if isSpeech {
            speechMs += frameMs
            trailingSilenceMs = 0
        } else {
            trailingSilenceMs += frameMs
        }

        if trailingSilenceMs >= configuration.pauseToCloseMs {
            return close(reason: .pause, now: now).map { [$0] } ?? []
        }
        if currentMs >= configuration.maximumUtteranceMs {
            return close(reason: .maxDuration, now: now).map { [$0] } ?? []
        }
        return []
    }

    public mutating func forceClose(now: Date = Date()) -> SpeechUtterance? {
        guard inSpeech else { return nil }
        return close(reason: .forced, now: now)
    }

    private mutating func append(_ frame: PCMAudioFrame, ms: Double) {
        current.append(frame)
        currentMs += ms
    }

    private mutating func pushPreRoll(_ frame: PCMAudioFrame, ms: Double) {
        preRoll.append(frame)
        preRollMs += ms
        while preRollMs > configuration.preRollMs, preRoll.count > 1 {
            preRollMs -= Self.durationMs(of: preRoll.removeFirst())
        }
    }

    private mutating func close(reason: SpeechUtterance.EndReason, now: Date) -> SpeechUtterance? {
        let frames = current
        let hadEnoughSpeech = speechMs >= configuration.minimumSpeechMs
        let overlapsPrevious = currentOverlapsPrevious
        current = []
        currentMs = 0
        speechMs = 0
        trailingSilenceMs = 0
        currentOverlapsPrevious = false

        if reason == .maxDuration {
            let tail = Self.tail(of: frames, lastMs: configuration.overlapMs)
            current = tail
            currentMs = tail.reduce(0) { $0 + Self.durationMs(of: $1) }
            speechMs = currentMs
            currentOverlapsPrevious = true
            inSpeech = true
        } else {
            inSpeech = false
        }

        guard hadEnoughSpeech else { return nil }
        return SpeechUtterance(frames: frames, endReason: reason, overlapsPrevious: overlapsPrevious, closedAt: now)
    }

    static func tail(of frames: [PCMAudioFrame], lastMs: Double) -> [PCMAudioFrame] {
        guard lastMs > 0 else { return [] }
        var result: [PCMAudioFrame] = []
        var accumulated: Double = 0
        for frame in frames.reversed() {
            result.insert(frame, at: 0)
            accumulated += durationMs(of: frame)
            if accumulated >= lastMs { break }
        }
        return result
    }

    public static func durationMs(of frame: PCMAudioFrame) -> Double {
        guard frame.sampleRate > 0, frame.channelCount > 0 else { return 0 }
        return Double(frame.samples.count) / Double(frame.channelCount) / Double(frame.sampleRate) * 1000
    }

    static func rms(of frame: PCMAudioFrame) -> Double {
        guard !frame.samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in frame.samples {
            let normalized = Double(sample) / Double(Int16.max)
            sum += normalized * normalized
        }
        return (sum / Double(frame.samples.count)).squareRoot()
    }
}
