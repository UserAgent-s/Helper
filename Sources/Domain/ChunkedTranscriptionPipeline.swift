public actor ChunkedTranscriptionPipeline {
    private let transcribing: any LocalTranscribing
    private let chunkDurationSeconds: Double
    private let overlapSeconds: Double

    private var workingFrames: [PCMAudioFrame] = []
    private var workingDurationMs: Double = 0
    private var bufferAbsoluteStartMs: Double = 0
    private var hasFlushedOnce = false

    public init(
        transcribing: any LocalTranscribing,
        chunkDurationSeconds: Double = 8,
        overlapSeconds: Double = 1.5
    ) {
        self.transcribing = transcribing
        self.chunkDurationSeconds = chunkDurationSeconds
        self.overlapSeconds = overlapSeconds
    }

    public func ingest(_ frame: PCMAudioFrame) -> Bool {
        workingFrames.append(frame)
        workingDurationMs += Self.durationMs(of: frame)
        return workingDurationMs >= chunkDurationSeconds * 1000
    }

    public func flush() async throws -> [TranscribedSegment] {
        guard !workingFrames.isEmpty else { return [] }
        let framesToTranscribe = workingFrames
        let overlapMs = overlapSeconds * 1000

        let allSegments = try await transcribing.transcribe(framesToTranscribe)
        let newSegments = hasFlushedOnce ? allSegments.filter { Double($0.startMs) >= overlapMs } : allSegments
        let bufferStartMsSnapshot = bufferAbsoluteStartMs
        let absoluteSegments = newSegments.map { segment in
            TranscribedSegment(
                text: segment.text,
                startMs: segment.startMs + Int(bufferStartMsSnapshot),
                endMs: segment.endMs + Int(bufferStartMsSnapshot),
                source: segment.source,
                language: segment.language,
                confidence: segment.confidence
            )
        }

        let tail = Self.tailFrames(of: framesToTranscribe, lastSeconds: overlapSeconds)
        let consumedMs = Self.durationMs(of: framesToTranscribe) - Self.durationMs(of: tail)
        bufferAbsoluteStartMs += consumedMs
        workingFrames = tail
        workingDurationMs = Self.durationMs(of: tail)
        hasFlushedOnce = true

        return absoluteSegments
    }

    private static func durationMs(of frame: PCMAudioFrame) -> Double {
        guard frame.sampleRate > 0, frame.channelCount > 0 else { return 0 }
        let sampleCount = Double(frame.samples.count) / Double(frame.channelCount)
        return sampleCount / Double(frame.sampleRate) * 1000
    }

    private static func durationMs(of frames: [PCMAudioFrame]) -> Double {
        frames.reduce(0) { $0 + durationMs(of: $1) }
    }

    private static func tailFrames(of frames: [PCMAudioFrame], lastSeconds: Double) -> [PCMAudioFrame] {
        guard lastSeconds > 0 else { return [] }
        let targetMs = lastSeconds * 1000
        var tail: [PCMAudioFrame] = []
        var accumulatedMs: Double = 0
        for frame in frames.reversed() {
            tail.insert(frame, at: 0)
            accumulatedMs += durationMs(of: frame)
            if accumulatedMs >= targetMs { break }
        }
        return tail
    }
}
