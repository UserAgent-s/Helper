import Diagnostics
import Domain
import Foundation
import RealtimeClient
import Testing

private actor ScriptedMicrophone: MicrophoneCapturing {
    private var continuation: AsyncStream<PCMAudioFrame>.Continuation?

    func start(options: MicrophoneCaptureOptions) async throws -> AsyncStream<PCMAudioFrame> {
        let (stream, continuation) = AsyncStream<PCMAudioFrame>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }

    func emit(_ frame: PCMAudioFrame) {
        continuation?.yield(frame)
    }
}

private actor ScriptedSystemAudio: SystemAudioCapturing {
    private var continuation: AsyncStream<PCMAudioFrame>.Continuation?

    func start(scope: SystemAudioScope) async throws -> SystemAudioCaptureStart {
        let (stream, continuation) = AsyncStream<PCMAudioFrame>.makeStream()
        self.continuation = continuation
        return SystemAudioCaptureStart(frames: stream, effectiveScope: scope)
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }

    func emit(_ frame: PCMAudioFrame) {
        continuation?.yield(frame)
    }
}

private actor TimedTranscriber: MeTranscribing {
    private let inner: OpenAIRealtimeTranscriptionClient
    private let clock = ContinuousClock()
    private(set) var commits: [ContinuousClock.Instant] = []

    init(_ inner: OpenAIRealtimeTranscriptionClient) {
        self.inner = inner
    }

    func start(languages: [String]) async throws -> AsyncStream<TranscriptDelta> {
        try await inner.start(languages: languages)
    }

    func appendAudio(_ frame: PCMAudioFrame) async {
        await inner.appendAudio(frame)
    }

    func commitTurn() async {
        commits.append(clock.now)
        await inner.commitTurn()
    }

    nonisolated func statusUpdates() -> AsyncStream<MeTranscriptionStatus> {
        inner.statusUpdates()
    }

    func stop() async {
        await inner.stop()
    }
}

private actor RecordingResponder: LiveResponder {
    private(set) var injected: [InjectedContext] = []

    nonisolated var capabilities: ProviderCapabilities { [.textInjection] }
    func start(instructions: String) async throws {}
    func appendAudio(_ frame: PCMAudioFrame) async {}
    nonisolated func events() -> AsyncStream<RealtimeAnswerEvent> { AsyncStream { $0.finish() } }
    func injectContext(_ context: InjectedContext) async throws { injected.append(context) }
    func forceResponse() async throws {}
    func resetContext() async {}
    func stop() async {}
}

private actor ArrivalLog {
    private let clock = ContinuousClock()
    private(set) var arrivals: [(at: ContinuousClock.Instant, text: String)] = []

    func record(_ text: String) {
        arrivals.append((clock.now, text))
    }

    var count: Int { arrivals.count }
}

private struct MePhrase: Sendable {
    let text: String
    let voice: String?
}

private let mePhrases: [MePhrase] = [
    MePhrase(text: "Я пять лет писал бэкенд на Go и Kafka.", voice: "Milena"),
    MePhrase(text: "Мы перешли на Postgres из-за транзакций.", voice: "Milena"),
    MePhrase(text: "Я бы начал с профилирования запросов.", voice: "Milena"),
    MePhrase(text: "I led the migration to Kubernetes last year.", voice: nil),
    MePhrase(text: "We cut latency by caching the hot paths.", voice: nil),
    MePhrase(text: "I would start by measuring the queue depth.", voice: nil),
]

private let remotePhrases: [MePhrase] = [
    MePhrase(text: "Tell me about the hardest bug you fixed last year.", voice: nil),
    MePhrase(text: "How would you design a rate limiter for a public API?", voice: nil),
    MePhrase(text: "Расскажите, как вы проектировали платёжный сервис.", voice: "Milena"),
    MePhrase(text: "Почему вы выбрали Kafka, а не RabbitMQ?", voice: "Milena"),
]

private func waitFor(timeout: Duration, _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

@Suite(.enabled(if: RealAPIEnvironment.isEnabled), .serialized)
struct MeChannelLatencyTests {
    @Test func meTranscriptCompletedAfterPause() async throws {
        let microphone = ScriptedMicrophone()
        let hub = CaptureHub(system: ScriptedSystemAudio(), microphone: microphone)
        let transcriber = TimedTranscriber(OpenAIRealtimeTranscriptionClient(credentialProviding: EnvironmentCredentialProvider()))
        let sink = MeTranscriptionSink(captureHub: hub, transcriber: transcriber, responder: RecordingResponder(), dedupGrace: .zero)
        let log = ArrivalLog()
        let transcripts = sink.transcripts(subscriber: "verify-real.me")
        let reader = Task {
            for await event in transcripts { await log.record(event.text) }
        }
        let started = await sink.start()
        try #require(started)

        let clock = ContinuousClock()
        let emitter = PacedFrameEmitter()
        let feed: @Sendable (PCMAudioFrame) async -> Void = { await microphone.emit($0) }
        var fromSpeechEnd: [Int] = []
        var fromCommit: [Int] = []
        var texts: [String] = []
        let rounds = RealAPIEnvironment.rounds(default: 1)

        for _ in 0..<rounds {
            for phrase in mePhrases {
                let speech = try SpeechFixture.pcm24k(phrase.text, voice: phrase.voice)
                let expected = await log.count + 1
                await emitter.emit(SpeechFixture.silence(ms: 400) + speech, source: .microphone, sink: feed)
                let speechEnd = clock.now
                await emitter.emit(SpeechFixture.silence(ms: 1_500), source: .microphone, sink: feed)
                let arrived = await waitFor(timeout: .seconds(10)) { await log.count >= expected }
                guard arrived else {
                    Issue.record("no completed transcript for: \(phrase.text)")
                    continue
                }
                let arrival = await log.arrivals[expected - 1]
                texts.append(arrival.text)
                fromSpeechEnd.append((arrival.at - speechEnd).milliseconds)
                if let commit = await transcriber.commits.last(where: { $0 <= arrival.at }) {
                    fromCommit.append((arrival.at - commit).milliseconds)
                }
            }
        }

        await sink.stop()
        reader.cancel()

        let afterSpeech = LatencySummary(label: "me.speech_end_to_completed", valuesMs: fromSpeechEnd)
        let afterPause = LatencySummary(label: "me.commit_to_completed", valuesMs: fromCommit)
        print(afterSpeech)
        print(afterPause)
        print("VERIFY_REAL me.transcripts \(texts)")
        #expect(fromCommit.count == mePhrases.count * rounds)
        #expect(afterPause.p50 <= 1_500)
    }

    @Test func answerNowWithInjectedContextToFirstDelta() async throws {
        let clock = ContinuousClock()
        let emitter = PacedFrameEmitter()
        let explanation = try SpeechFixture.pcm24k("Let me describe our order service. It writes to Postgres and publishes events to Kafka.")
        var latencies: [Int] = []
        let rounds = RealAPIEnvironment.rounds(default: 3)

        for _ in 0..<rounds {
            let client = OpenAIRealtimeAnswerClient(credentialProviding: EnvironmentCredentialProvider(), latencyRecording: NoOpLatencyRecorder())
            try await client.start(instructions: RealtimeInstructions.system(for: .short))
            try await client.injectContext(.me("Я пять лет писал бэкенд на Go и Kafka."))
            try await client.injectContext(.screen(application: "Xcode", text: "func handle(order: Order) async throws { try await repository.save(order); try await bus.publish(order) }"))
            let feed: @Sendable (PCMAudioFrame) async -> Void = { await client.appendAudio($0) }
            await emitter.emit(explanation + SpeechFixture.silence(ms: 600), source: .systemAudio, sink: feed)
            let events = client.events()
            let pressed = clock.now
            try await client.forceResponse()
            let first: Duration? = await withTaskGroup(of: Duration?.self) { group in
                group.addTask {
                    for await event in events {
                        if case .textDelta = event { return clock.now - pressed }
                    }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(20))
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }
            await client.stop()
            if let first { latencies.append(first.milliseconds) } else { Issue.record("no text delta after Answer now") }
        }

        print(LatencySummary(label: "answer_now_with_injected_context_to_first_delta", valuesMs: latencies))
        #expect(latencies.count == rounds)
    }

    @Test func syntheticSpeakerEchoLeak() async throws {
        let rounds = RealAPIEnvironment.rounds(default: 1)
        for attenuation in [-10.0, -20.0, -30.0] {
            let microphone = ScriptedMicrophone()
            let system = ScriptedSystemAudio()
            let hub = CaptureHub(system: system, microphone: microphone)
            let transcriber = TimedTranscriber(OpenAIRealtimeTranscriptionClient(credentialProviding: EnvironmentCredentialProvider()))
            let responder = RecordingResponder()
            let sink = MeTranscriptionSink(captureHub: hub, transcriber: transcriber, responder: responder)
            let systemSubscription = try await hub.acquire(.systemAudio, consumer: "verify-real.system", policy: .bufferingNewest(250))
            let drain = Task { for await _ in systemSubscription.frames {} }
            let started = await sink.start()
            try #require(started)

            let emitter = PacedFrameEmitter()
            var played = 0
            for _ in 0..<rounds {
                for (index, phrase) in remotePhrases.enumerated() {
                    let remote = try SpeechFixture.pcm24k(phrase.text, voice: phrase.voice)
                    let echo = SpeechFixture.attenuated(remote, decibels: attenuation, delayMs: 40)
                    let length = max(remote.count, echo.count)
                    let systemTrack = remote + Array(repeating: 0, count: length - remote.count)
                    let micTrack = echo + Array(repeating: 0, count: length - echo.count)
                    let pairs = stride(from: 0, to: length, by: 480).map { start -> ([Int16], [Int16]) in
                        let end = min(start + 480, length)
                        return (Array(systemTrack[start..<end]), Array(micTrack[start..<end]))
                    }
                    for (systemChunk, micChunk) in pairs {
                        let at = Date()
                        await system.emit(PCMAudioFrame(samples: systemChunk, sampleRate: 24_000, channelCount: 1, capturedAt: at, source: .systemAudio))
                        await microphone.emit(PCMAudioFrame(samples: micChunk, sampleRate: 24_000, channelCount: 1, capturedAt: at, source: .microphone))
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    await sink.noteRemoteTranscript(TranscriptEvent(speaker: .them, itemID: "them_\(index)", text: phrase.text, isFinal: true))
                    await emitter.emit(SpeechFixture.silence(ms: 1_500), source: .microphone, sink: { await microphone.emit($0) })
                    played += 1
                }
            }
            try? await Task.sleep(for: .seconds(4))
            let opened = await sink.committedTurnCount
            let dropped = await sink.droppedEchoCount
            let injected = await responder.injected.count
            await sink.stop()
            await hub.release(systemSubscription)
            drain.cancel()
            print("VERIFY_REAL me.echo_leak attenuation=\(Int(attenuation))dB phrases=\(played) turns_opened=\(opened) dropped_by_dedup=\(dropped) injected=\(injected)")
            #expect(played == remotePhrases.count * rounds)
        }
    }
}
