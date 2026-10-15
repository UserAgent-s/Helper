import Domain

public struct NoOpLatencyRecorder: LatencyRecording {
    public init() {}

    public func record(_ metric: LatencyMetric) async {}
}
