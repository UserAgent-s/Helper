import Domain
import Testing
@testable import Diagnostics

@Suite struct LatencyReportBuilderTests {

    @Test func computesCountP50P95AndMaxPerKind() {
        let values = (1...100).map { LatencyMetric.responseTotalMs($0 * 10) }
        let report = LatencyReportBuilder.build(from: values)

        let entry = report.first { $0.kindLabel == "responseTotalMs" }
        #expect(entry?.count == 100)
        #expect(entry?.max == 1000)
        #expect(entry?.p50 == 510)
        #expect(entry?.p95 == 960)
    }

    @Test func groupsDifferentKindsIndependently() {
        let metrics: [LatencyMetric] = [
            .speechEndToFirstDeltaMs(100),
            .speechEndToFirstDeltaMs(200),
            .responseTotalMs(5000),
        ]
        let report = LatencyReportBuilder.build(from: metrics)

        #expect(report.first { $0.kindLabel == "speechEndToFirstDeltaMs" }?.count == 2)
        #expect(report.first { $0.kindLabel == "responseTotalMs" }?.count == 1)
    }

    @Test func nonMillisecondMetricsAreExcludedFromTimingReport() {
        let metrics: [LatencyMetric] = [.droppedAudioFrames(5), .duplicatedAudioFrames(2)]
        let report = LatencyReportBuilder.build(from: metrics)
        #expect(report.isEmpty)
    }

    @Test func emptyInputProducesEmptyReport() {
        #expect(LatencyReportBuilder.build(from: []).isEmpty)
    }
}
