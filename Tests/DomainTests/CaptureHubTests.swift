import Foundation
import Testing
@testable import Domain

private actor EventLog {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}

private actor ScriptedSystemAudio: SystemAudioCapturing {
    private var continuation: AsyncStream<PCMAudioFrame>.Continuation?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private let log: EventLog

    init(log: EventLog = EventLog()) {
        self.log = log
    }

    func start(scope: SystemAudioScope) async throws -> SystemAudioCaptureStart {
        startCallCount += 1
        let (stream, continuation) = AsyncStream<PCMAudioFrame>.makeStream()
        self.continuation = continuation
        return SystemAudioCaptureStart(frames: stream, effectiveScope: scope)
    }

    func stop() async {
        stopCallCount += 1
        await log.append("system.stop")
        continuation?.finish()
        continuation = nil
    }

    func emit(_ frame: PCMAudioFrame) {
        continuation?.yield(frame)
    }

    func endUnexpectedly() {
        continuation?.finish()
        continuation = nil
    }
}

private actor ScriptedMicrophone: MicrophoneCapturing {
    private var continuation: AsyncStream<PCMAudioFrame>.Continuation?
    private let log: EventLog

    init(log: EventLog = EventLog()) {
        self.log = log
    }

    func start() async throws -> AsyncStream<PCMAudioFrame> {
        let (stream, continuation) = AsyncStream<PCMAudioFrame>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() async {
        await log.append("microphone.stop")
        continuation?.finish()
        continuation = nil
    }
}

private func frame(_ value: Int16) -> PCMAudioFrame {
    PCMAudioFrame(samples: Array(repeating: value, count: 480), sampleRate: 24_000, channelCount: 1, capturedAt: Date(), source: .systemAudio)
}

private actor FrameCounter {
    private(set) var values: [Int16] = []

    func add(_ frame: PCMAudioFrame) {
        values.append(frame.samples.first ?? 0)
    }
}

private func waitUntil(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Suite struct CaptureHubTests {

    @Test func firstAcquireStartsSourceLastReleaseStops() async throws {
        let system = ScriptedSystemAudio()
        let hub = CaptureHub(system: system, microphone: ScriptedMicrophone())

        let first = try await hub.acquire(.systemAudio, consumer: "a", policy: .unbounded)
        let second = try await hub.acquire(.systemAudio, consumer: "b", policy: .unbounded)
        #expect(await system.startCallCount == 1)
        #expect(await hub.activeSources == [.systemAudio])

        await hub.release(first)
        #expect(await system.stopCallCount == 0)
        await hub.release(second)
        #expect(await system.stopCallCount == 1)
        #expect(await hub.activeSources.isEmpty)
    }

    @Test func twoConsumersReceiveSameFrames() async throws {
        let system = ScriptedSystemAudio()
        let hub = CaptureHub(system: system, microphone: ScriptedMicrophone())
        let a = try await hub.acquire(.systemAudio, consumer: "a", policy: .unbounded)
        let b = try await hub.acquire(.systemAudio, consumer: "b", policy: .unbounded)
        let counterA = FrameCounter()
        let counterB = FrameCounter()
        let taskA = Task { for await f in a.frames { await counterA.add(f) } }
        let taskB = Task { for await f in b.frames { await counterB.add(f) } }

        for value in Int16(1)...5 { await system.emit(frame(value)) }
        await waitUntil { let a = await counterA.values.count; let b = await counterB.values.count; return a == 5 && b == 5 }

        #expect(await counterA.values == [1, 2, 3, 4, 5])
        #expect(await counterB.values == [1, 2, 3, 4, 5])
        await hub.stopAll()
        _ = await (taskA.value, taskB.value)
    }

    @Test func slowConsumerDoesNotReduceRealtimeFrameCount() async throws {
        let system = ScriptedSystemAudio()
        let hub = CaptureHub(system: system, microphone: ScriptedMicrophone())
        let realtime = try await hub.acquire(.systemAudio, consumer: "realtime", policy: .bufferingNewest(500))
        let stuck = try await hub.acquire(.systemAudio, consumer: "stuck", policy: .bufferingNewest(10))
        let counter = FrameCounter()
        let realtimeTask = Task { for await f in realtime.frames { await counter.add(f) } }

        for index in 0..<500 { await system.emit(frame(Int16(index % 1000))) }
        await waitUntil { await counter.values.count == 500 }

        #expect(await counter.values.count == 500)
        #expect(await hub.droppedFrames(consumer: "realtime") == 0)
        #expect(await hub.droppedFrames(consumer: "stuck") == 490)
        _ = stuck
        await hub.stopAll()
        await realtimeTask.value
    }

    @Test func sourceEndedUnexpectedlyReportsFailure() async throws {
        let system = ScriptedSystemAudio()
        let hub = CaptureHub(system: system, microphone: ScriptedMicrophone())
        var failures = hub.failures().makeAsyncIterator()
        let subscription = try await hub.acquire(.systemAudio, consumer: "a", policy: .unbounded)
        let consumer = Task { for await _ in subscription.frames {} }

        await system.endUnexpectedly()

        #expect(await failures.next() == "systemAudio_capture_ended")
        await consumer.value
        #expect(await hub.activeSources.isEmpty)
    }

    @Test func stopAllReleasesInReverseOrder() async throws {
        let log = EventLog()
        let hub = CaptureHub(system: ScriptedSystemAudio(log: log), microphone: ScriptedMicrophone(log: log))
        _ = try await hub.acquire(.systemAudio, consumer: "a", policy: .unbounded)
        _ = try await hub.acquire(.microphone, consumer: "b", policy: .unbounded)

        await hub.stopAll()

        #expect(await log.entries == ["microphone.stop", "system.stop"])
        #expect(await hub.activeSources.isEmpty)
    }

    @Test func levelsArriveTenTimesPerSecondPerSource() async throws {
        let system = ScriptedSystemAudio()
        let hub = CaptureHub(system: system, microphone: ScriptedMicrophone())
        let levels = hub.levels.subscribe("test")
        _ = try await hub.acquire(.systemAudio, consumer: "a", policy: .bufferingNewest(1))

        for frame in SyntheticAudioFixtures.toneBurst(durationMs: 1000, sampleRate: 24_000) { await system.emit(frame) }

        var received: [AudioLevel] = []
        for await level in levels {
            received.append(level)
            if received.count == 10 { break }
        }
        #expect(received.count == 10)
        #expect(received.allSatisfy { $0.kind == .systemAudio })
        await hub.stopAll()
    }
}
