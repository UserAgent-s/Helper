import Domain
import Foundation
import Testing
@testable import RealtimeClient

private actor IdleSystemAudio: SystemAudioCapturing {
    func start(scope: SystemAudioScope) async throws -> SystemAudioCaptureStart {
        SystemAudioCaptureStart(frames: AsyncStream { _ in }, effectiveScope: scope)
    }
    func stop() async {}
}

private actor ScriptedMeMicrophone: MicrophoneCapturing {
    private var continuation: AsyncStream<PCMAudioFrame>.Continuation?
    private(set) var requestedOptions: MicrophoneCaptureOptions?

    func start(options: MicrophoneCaptureOptions) async throws -> AsyncStream<PCMAudioFrame> {
        requestedOptions = options
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

private func speechFrames(start: Date) -> [PCMAudioFrame] {
    let rate = 24_000
    var frames: [PCMAudioFrame] = []
    let pattern: [(Int, Double)] = [(400, 0), (900, 6_000), (900, 0)]
    var offsetMs = 0
    var index = 0
    for (durationMs, amplitude) in pattern {
        for _ in 0..<(durationMs / 20) {
            var samples: [Int16] = []
            for _ in 0..<(rate / 50) {
                samples.append(Int16(sin(Double(index) / Double(rate) * 2 * .pi * 220) * amplitude))
                index += 1
            }
            frames.append(PCMAudioFrame(samples: samples, sampleRate: rate, channelCount: 1, capturedAt: start.addingTimeInterval(Double(offsetMs) / 1000), source: .microphone))
            offsetMs += 20
        }
    }
    return frames
}

@Suite struct MeChannelIntegrationTests {
    @Test func meSpeechBecomesTaggedItemCreateWithoutResponseCreate() async throws {
        let answerTransport = FakeRealtimeWebSocketTransport()
        let meTransport = FakeRealtimeWebSocketTransport()
        let answers = OpenAIRealtimeAnswerClient(
            transport: answerTransport,
            credentialProviding: FakeCredentialProviding(),
            latencyRecording: RecordingLatencyRecorder(),
            reconnectBaseDelay: .milliseconds(10),
            maxReconnectAttempts: 1
        )
        let me = OpenAIRealtimeTranscriptionClient(transport: meTransport, credentialProviding: FakeCredentialProviding())
        let microphone = ScriptedMeMicrophone()
        let hub = CaptureHub(system: IdleSystemAudio(), microphone: microphone)
        let sink = MeTranscriptionSink(captureHub: hub, transcriber: me, responder: answers, dedupGrace: .zero)
        let controller = AnswersModeController(
            captureHub: hub,
            realtime: answers,
            answerTrigger: ManualAnswerTrigger(),
            instructionsProvider: { "test" },
            meChannel: sink
        )

        try await controller.start()
        #expect(await microphone.requestedOptions?.sampleRate == 24_000)
        #expect(meTransport.sentEventTypes == ["session.update"])

        let frames = speechFrames(start: Date())
        for frame in frames { await microphone.emit(frame) }
        await waitUntil { await sink.processedFrameCount >= frames.count }
        #expect(meTransport.sentEventTypes.filter { $0 == "input_audio_buffer.commit" }.count == 1)
        #expect(meTransport.sentEventTypes.contains("input_audio_buffer.append"))

        meTransport.emit(.inputAudioTranscriptionCompleted(itemID: "me_item_1", transcript: "Я бы начал с профилирования", language: "ru"))
        await waitUntil {
            answerTransport.sentEvents.contains { if case .conversationItemCreate = $0 { true } else { false } }
        }
        try await Task.sleep(for: .milliseconds(30))
        let created = answerTransport.sentEvents.compactMap { if case .conversationItemCreate(let payload) = $0 { payload } else { nil } }
        #expect(created.map(\.text) == ["[Я]: Я бы начал с профилирования"])
        #expect(!answerTransport.sentEventTypes.contains("response.create"))

        await controller.stop()
        #expect(await hub.activeSources.isEmpty)
        #expect(meTransport.closeCallCount >= 1)
    }
}
