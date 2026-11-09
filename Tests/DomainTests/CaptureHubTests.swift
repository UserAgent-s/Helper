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
    private(set) var startedOptions: [MicrophoneCaptureOptions] = []

    init(log: EventLog = EventLog()) {
        self.log = log
    }

    func start(options: MicrophoneCaptureOptions) async throws -> AsyncStream<PCMAudioFrame> {
        startedOptions.append(options)
        let (stream, continuation) = AsyncStream<PCMAudioFrame>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() async {
        await log.append("microphone.stop")
        continuation?.finish()
        continuation = nil
    }

    func emit(_ frame: PCMAudioFrame) {
        continuation?.yield(frame)
    }
}

private actor MutablePlan {
    var plan = MicrophoneStartPlan(options: MicrophoneCaptureOptions(deviceUID: "USBHeadset"))

    func set(_ plan: MicrophoneStartPlan) {
        self.plan = plan
    }
}

private actor RouteState {
    var route: OutputRoute = .wiredHeadphones
    private(set) var requestedProfiles: [MicrophoneProfile] = []

    func set(_ route: OutputRoute) {
        self.route = route
    }

    func plan(_ profile: MicrophoneProfile) -> MicrophoneStartPlan {
        requestedProfiles.append(profile)
        return MicrophoneStartPlan(options: profile.options(deviceUID: "BuiltInMic", route: route, policy: .auto))
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

    @Test func microphoneRestartOnDeviceChangeKeepsSubscribers() async throws {
        let microphone = ScriptedMicrophone()
        let plan = MutablePlan()
        let hub = CaptureHub(system: ScriptedSystemAudio(), microphone: microphone, microphonePlan: { _ in await plan.plan })
        let notices = hub.notices.subscribe("test")
        let subscription = try await hub.acquire(.microphone, consumer: "recorder", policy: .unbounded)
        let counter = FrameCounter()
        let consumer = Task { for await f in subscription.frames { await counter.add(f) } }

        await microphone.emit(frame(1))
        await hub.handleDeviceChange(.deviceListChanged)
        #expect(await microphone.startedOptions.count == 1)

        let fallback = CaptureNotice.microphoneFellBack(from: "USBHeadset", to: "MacBook Pro Microphone", reason: .selectedDeviceMissing)
        await plan.set(MicrophoneStartPlan(options: MicrophoneCaptureOptions(deviceUID: "BuiltInMic"), notice: fallback))
        await hub.handleDeviceChange(.deviceListChanged)
        await microphone.emit(frame(2))
        await waitUntil { await counter.values.count == 2 }

        #expect(await counter.values == [1, 2])
        #expect(await microphone.startedOptions.map(\.deviceUID) == ["USBHeadset", "BuiltInMic"])
        #expect(await hub.microphoneDeviceUID == "BuiltInMic")
        var iterator = notices.makeAsyncIterator()
        #expect(await iterator.next() == fallback)
        await hub.stopAll()
        await consumer.value
    }

    @Test func engineReconfigurationAlwaysRestartsMicrophone() async throws {
        let microphone = ScriptedMicrophone()
        let hub = CaptureHub(system: ScriptedSystemAudio(), microphone: microphone)
        _ = try await hub.acquire(.microphone, consumer: "recorder", policy: .unbounded)
        await hub.handleDeviceChange(.microphoneEngineReconfigured)
        await hub.handleDeviceChange(.defaultOutputChanged)
        #expect(await microphone.startedOptions.count == 2)
        await hub.stopAll()
    }

    @Test func meProfileStartsMicrophoneAt24kHzAndRecordingAt16kHz() async throws {
        let microphone = ScriptedMicrophone()
        let state = RouteState()
        let hub = CaptureHub(system: ScriptedSystemAudio(), microphone: microphone, microphonePlan: { await state.plan($0) })
        let me = try await hub.acquire(.microphone, consumer: "me", policy: .bufferingNewest(50), microphoneProfile: .me)
        #expect(await microphone.startedOptions.last?.sampleRate == 24_000)
        #expect(await hub.microphoneOptions?.sampleRate == 24_000)
        await hub.release(me)
        _ = try await hub.acquire(.microphone, consumer: "recorder")
        #expect(await microphone.startedOptions.last?.sampleRate == 16_000)
        #expect(await state.requestedProfiles == [.me, .recording])
        await hub.stopAll()
    }

    @Test func switchingToSpeakersRestartsMeMicrophoneWithVoiceProcessingAndKeepsSubscriber() async throws {
        let microphone = ScriptedMicrophone()
        let state = RouteState()
        let hub = CaptureHub(system: ScriptedSystemAudio(), microphone: microphone, microphonePlan: { await state.plan($0) })
        let subscription = try await hub.acquire(.microphone, consumer: "me", policy: .unbounded, microphoneProfile: .me)
        let counter = FrameCounter()
        let consumer = Task { for await f in subscription.frames { await counter.add(f) } }
        #expect(await microphone.startedOptions.map(\.voiceProcessing) == [false])

        await microphone.emit(frame(1))
        await state.set(.builtInSpeakers)
        await hub.handleDeviceChange(.defaultOutputChanged)
        await microphone.emit(frame(2))
        await waitUntil { await counter.values.count == 2 }

        #expect(await microphone.startedOptions.map(\.voiceProcessing) == [false, true])
        #expect(await hub.microphoneOptions?.voiceProcessing == true)
        #expect(await counter.values == [1, 2])

        await hub.handleDeviceChange(.outputDataSourceChanged)
        #expect(await microphone.startedOptions.count == 2)
        await hub.stopAll()
        await consumer.value
    }

    @Test func recordingMicrophoneIgnoresOutputRouteChanges() async throws {
        let microphone = ScriptedMicrophone()
        let state = RouteState()
        let hub = CaptureHub(system: ScriptedSystemAudio(), microphone: microphone, microphonePlan: { await state.plan($0) })
        _ = try await hub.acquire(.microphone, consumer: "recorder")
        await state.set(.builtInSpeakers)
        await hub.handleDeviceChange(.defaultOutputChanged)
        await hub.refreshMicrophonePlan()
        #expect(await microphone.startedOptions.map(\.voiceProcessing) == [false])
        await hub.stopAll()
    }

    @Test func releasingMeMicrophoneTearsItDownForPassive() async throws {
        let log = EventLog()
        let microphone = ScriptedMicrophone(log: log)
        let state = RouteState()
        await state.set(.builtInSpeakers)
        let hub = CaptureHub(system: ScriptedSystemAudio(), microphone: microphone, microphonePlan: { await state.plan($0) })
        let me = try await hub.acquire(.microphone, consumer: "me", microphoneProfile: .me)
        #expect(await microphone.startedOptions.last?.voiceProcessing == true)
        await hub.release(me)
        #expect(await hub.activeSources.isEmpty)
        #expect(await hub.microphoneOptions == nil)
        #expect(await log.entries.contains("microphone.stop"))
        await hub.handleDeviceChange(.defaultOutputChanged)
        #expect(await microphone.startedOptions.count == 1)
    }
}
