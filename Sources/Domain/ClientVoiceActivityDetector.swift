import Foundation

public struct ClientVADConfiguration: Sendable, Equatable {
    public var windowMs: Int
    public var absoluteOpenDBFS: Float
    public var marginOverNoiseDB: Float
    public var closeHysteresisDB: Float
    public var onsetMs: Int
    public var hangoverMs: Int
    public var maxTurnMs: Int
    public var noiseFloorAdaptation: Float
    public var initialNoiseFloorDBFS: Float
    public var minimumNoiseFloorDBFS: Float

    public init(
        windowMs: Int = 20,
        absoluteOpenDBFS: Float = -45,
        marginOverNoiseDB: Float = 12,
        closeHysteresisDB: Float = 4,
        onsetMs: Int = 60,
        hangoverMs: Int = 600,
        maxTurnMs: Int = 15_000,
        noiseFloorAdaptation: Float = 0.05,
        initialNoiseFloorDBFS: Float = -70,
        minimumNoiseFloorDBFS: Float = -90
    ) {
        self.windowMs = max(1, windowMs)
        self.absoluteOpenDBFS = absoluteOpenDBFS
        self.marginOverNoiseDB = marginOverNoiseDB
        self.closeHysteresisDB = closeHysteresisDB
        self.onsetMs = onsetMs
        self.hangoverMs = hangoverMs
        self.maxTurnMs = maxTurnMs
        self.noiseFloorAdaptation = noiseFloorAdaptation
        self.initialNoiseFloorDBFS = initialNoiseFloorDBFS
        self.minimumNoiseFloorDBFS = minimumNoiseFloorDBFS
    }
}

public enum ClientVADEvent: Sendable, Equatable {
    case opened
    case closed(durationMs: Int, forced: Bool)
}

public struct ClientVoiceActivityDetector: Sendable {
    public let configuration: ClientVADConfiguration
    public private(set) var isOpen = false
    public private(set) var noiseFloorDBFS: Float

    private var sumOfSquares: Double = 0
    private var pendingSamples = 0
    private var aboveMs = 0
    private var belowMs = 0
    private var openMs = 0

    public init(configuration: ClientVADConfiguration = ClientVADConfiguration()) {
        self.configuration = configuration
        self.noiseFloorDBFS = configuration.initialNoiseFloorDBFS
    }

    public var openThresholdDBFS: Float {
        max(configuration.absoluteOpenDBFS, noiseFloorDBFS + configuration.marginOverNoiseDB)
    }

    public mutating func reset() {
        self = ClientVoiceActivityDetector(configuration: configuration)
    }

    public mutating func ingest(_ frame: PCMAudioFrame, openingAllowed: Bool = true) -> [ClientVADEvent] {
        guard frame.sampleRate > 0, !frame.samples.isEmpty else { return [] }
        let windowSamples = max(1, frame.sampleRate * configuration.windowMs / 1000 * max(1, frame.channelCount))
        var events: [ClientVADEvent] = []
        for sample in frame.samples {
            let value = Double(sample)
            sumOfSquares += value * value
            pendingSamples += 1
            if pendingSamples >= windowSamples {
                let rms = (sumOfSquares / Double(pendingSamples)).squareRoot()
                sumOfSquares = 0
                pendingSamples = 0
                if let event = step(levelDBFS: AudioLevelMeter.dbfs(rms), openingAllowed: openingAllowed) {
                    events.append(event)
                }
            }
        }
        return events
    }

    private mutating func step(levelDBFS level: Float, openingAllowed: Bool) -> ClientVADEvent? {
        let window = configuration.windowMs
        if isOpen {
            openMs += window
            if level >= openThresholdDBFS - configuration.closeHysteresisDB {
                belowMs = 0
            } else {
                belowMs += window
            }
            let forced = openMs >= configuration.maxTurnMs
            guard belowMs >= configuration.hangoverMs || forced else { return nil }
            let duration = openMs
            isOpen = false
            openMs = 0
            belowMs = 0
            aboveMs = 0
            return .closed(durationMs: duration, forced: forced)
        }
        if level >= openThresholdDBFS {
            guard openingAllowed else {
                aboveMs = 0
                return nil
            }
            aboveMs += window
            guard aboveMs >= configuration.onsetMs else { return nil }
            isOpen = true
            openMs = aboveMs
            belowMs = 0
            aboveMs = 0
            return .opened
        }
        aboveMs = 0
        let target = max(configuration.minimumNoiseFloorDBFS, level)
        if target < noiseFloorDBFS {
            noiseFloorDBFS = target
        } else {
            noiseFloorDBFS += configuration.noiseFloorAdaptation * (target - noiseFloorDBFS)
        }
        return nil
    }
}
