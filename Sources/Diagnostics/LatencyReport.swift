import Domain

public struct LatencyReportEntry: Sendable, Equatable {
    public let kindLabel: String
    public let count: Int
    public let p50: Int
    public let p95: Int
    public let max: Int

    public init(kindLabel: String, count: Int, p50: Int, p95: Int, max: Int) {
        self.kindLabel = kindLabel
        self.count = count
        self.p50 = p50
        self.p95 = p95
        self.max = max
    }
}

public enum LatencyReportBuilder {
    public static func build(from metrics: [LatencyMetric]) -> [LatencyReportEntry] {
        var valuesByKind: [String: [Int]] = [:]
        for metric in metrics {
            guard let value = metric.millisecondValue else { continue }
            valuesByKind[metric.kindLabel, default: []].append(value)
        }

        return valuesByKind.keys.sorted().map { kind in
            let sortedValues = (valuesByKind[kind] ?? []).sorted()
            return LatencyReportEntry(
                kindLabel: kind,
                count: sortedValues.count,
                p50: percentile(sortedValues, 0.50),
                p95: percentile(sortedValues, 0.95),
                max: sortedValues.last ?? 0
            )
        }
    }

    private static func percentile(_ sortedValues: [Int], _ fraction: Double) -> Int {
        guard !sortedValues.isEmpty else { return 0 }
        let index = min(sortedValues.count - 1, Int(Double(sortedValues.count) * fraction))
        return sortedValues[index]
    }
}
