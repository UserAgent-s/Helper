import Domain
import Testing
@testable import Diagnostics

@Suite struct InMemoryLatencyRecorderTests {

    @Test func snapshotReturnsRecordedMetricsInOrder() async {
        let recorder = InMemoryLatencyRecorder()
        await recorder.record(.responseTotalMs(120))
        await recorder.record(.droppedAudioFrames(3))

        let snapshot = await recorder.snapshot()
        #expect(snapshot == [.responseTotalMs(120), .droppedAudioFrames(3)])
    }

    @Test func countsByKindGroupsWithoutExposingValues() async {
        let recorder = InMemoryLatencyRecorder()
        await recorder.record(.responseTotalMs(100))
        await recorder.record(.responseTotalMs(200))
        await recorder.record(.droppedAudioFrames(1))

        let counts = await recorder.countsByKind()
        #expect(counts["responseTotalMs"] == 2)
        #expect(counts["droppedAudioFrames"] == 1)
    }
}
