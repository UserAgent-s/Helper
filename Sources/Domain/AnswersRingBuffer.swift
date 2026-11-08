public actor AnswersRingBuffer {
    public let capacitySeconds: Double
    private var frames: [PCMAudioFrame] = []
    private var totalDurationMs: Double = 0

    public init(capacitySeconds: Double = 45) {
        self.capacitySeconds = capacitySeconds
    }

    public func append(_ frame: PCMAudioFrame) {
        frames.append(frame)
        totalDurationMs += Self.durationMs(of: frame)
        evictIfNeeded()
    }

    public func snapshot() -> [PCMAudioFrame] {
        frames
    }

    public func clear() {
        frames.removeAll()
        totalDurationMs = 0
    }

    public var durationSeconds: Double {
        totalDurationMs / 1000
    }

    public var frameCount: Int {
        frames.count
    }

    private func evictIfNeeded() {
        let capacityMs = capacitySeconds * 1000
        while totalDurationMs > capacityMs, !frames.isEmpty {
            let removed = frames.removeFirst()
            totalDurationMs -= Self.durationMs(of: removed)
        }
    }

    private static func durationMs(of frame: PCMAudioFrame) -> Double {
        guard frame.sampleRate > 0, frame.channelCount > 0 else { return 0 }
        let frameCount = Double(frame.samples.count) / Double(frame.channelCount)
        return frameCount / Double(frame.sampleRate) * 1000
    }
}
