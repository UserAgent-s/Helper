import Domain

public actor InMemoryLatencyRecorder: LatencyRecording {
    private var metrics: [LatencyMetric] = []

    public init() {}

    public func record(_ metric: LatencyMetric) async {
        metrics.append(metric)
    }

    public func snapshot() -> [LatencyMetric] {
        metrics
    }

    public func countsByKind() -> [String: Int] {
        var counts: [String: Int] = [:]
        for metric in metrics {
            counts[metric.kindLabel, default: 0] += 1
        }
        return counts
    }
}
