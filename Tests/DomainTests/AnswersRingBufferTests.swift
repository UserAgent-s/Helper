import Foundation
import Testing
@testable import Domain

@Suite struct AnswersRingBufferTests {

    private func frame(seconds: Double, at offset: TimeInterval = 0, sampleRate: Int = 24_000) -> PCMAudioFrame {
        let sampleCount = Int(Double(sampleRate) * seconds)
        let base = Date(timeIntervalSince1970: 1_000_000)
        return PCMAudioFrame(samples: [Int16](repeating: 0, count: sampleCount), sampleRate: sampleRate, channelCount: 1, capturedAt: base.addingTimeInterval(offset), source: .systemAudio)
    }

    @Test func neverExceedsCapacityDuration() async {
        let buffer = AnswersRingBuffer(capacitySeconds: 45)
        for i in 0..<100 {
            await buffer.append(frame(seconds: 1, at: Double(i)))
        }
        let duration = await buffer.durationSeconds
        #expect(duration <= 45)
        #expect(duration >= 44)
    }

    @Test func clearEmptiesBuffer() async {
        let buffer = AnswersRingBuffer(capacitySeconds: 45)
        await buffer.append(frame(seconds: 5))
        #expect(await buffer.frameCount == 1)

        await buffer.clear()

        #expect(await buffer.frameCount == 0)
        #expect(await buffer.durationSeconds == 0)
    }

    @Test func snapshotPreservesInsertionOrder() async {
        let buffer = AnswersRingBuffer(capacitySeconds: 45)
        let f1 = frame(seconds: 1, at: 0)
        let f2 = frame(seconds: 1, at: 1)
        await buffer.append(f1)
        await buffer.append(f2)

        let snapshot = await buffer.snapshot()
        #expect(snapshot.map(\.capturedAt) == [f1.capturedAt, f2.capturedAt])
    }

    @Test func evictsOldestFramesFirst() async {
        let buffer = AnswersRingBuffer(capacitySeconds: 2)
        let old = frame(seconds: 1, at: 0)
        await buffer.append(old)
        await buffer.append(frame(seconds: 1, at: 1))
        await buffer.append(frame(seconds: 1, at: 2))

        let snapshot = await buffer.snapshot()
        #expect(!snapshot.contains { $0.capturedAt == old.capturedAt })
    }
}
