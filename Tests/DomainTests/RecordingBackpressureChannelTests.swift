import Foundation
import Testing
@testable import Domain

@Suite struct RecordingBackpressureChannelTests {

    private func frame(tag: Int16) -> PCMAudioFrame {
        PCMAudioFrame(samples: [tag], sampleRate: 16_000, channelCount: 1, capturedAt: Date(), source: .microphone)
    }

    @Test func deliversFramesInOrderWhenUnderCapacity() async {
        let channel = RecordingBackpressureChannel(capacity: 10)
        await channel.send(frame(tag: 1))
        await channel.send(frame(tag: 2))

        let first = await channel.next()
        let second = await channel.next()

        #expect(first?.samples == [1])
        #expect(second?.samples == [2])
    }

    @Test func dropsOldestAndCountsMetricUnderOverload() async {
        let channel = RecordingBackpressureChannel(capacity: 2)
        await channel.send(frame(tag: 1))
        await channel.send(frame(tag: 2))
        await channel.send(frame(tag: 3))

        #expect(await channel.droppedFrameCount == 1)
        #expect(await channel.bufferedCount == 2)

        let first = await channel.next()
        #expect(first?.samples == [2])
    }

    @Test func neverExceedsBoundedMemory() async {
        let channel = RecordingBackpressureChannel(capacity: 5)
        for i in 0..<1000 {
            await channel.send(frame(tag: Int16(i % 100)))
        }
        #expect(await channel.bufferedCount <= 5)
        #expect(await channel.droppedFrameCount == 1000 - 5)
    }

    @Test func finishEndsConsumptionWithNil() async {
        let channel = RecordingBackpressureChannel(capacity: 5)
        await channel.send(frame(tag: 1))
        await channel.finish()

        let first = await channel.next()
        let second = await channel.next()

        #expect(first?.samples == [1])
        #expect(second == nil)
    }

    @Test func waitingConsumerReceivesFrameWithoutPolling() async throws {
        let channel = RecordingBackpressureChannel(capacity: 5)

        let consumerTask = Task { await channel.next() }
        try await Task.sleep(for: .milliseconds(20))
        await channel.send(frame(tag: 42))

        let received = await consumerTask.value
        #expect(received?.samples == [42])
    }
}
