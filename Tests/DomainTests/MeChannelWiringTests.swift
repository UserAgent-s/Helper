import Foundation
import Testing
@testable import Domain

@Suite struct MeChannelWiringTests {
    private func make(enabled: Bool = true) -> (AnswersModeController, CaptureHub, FakeMeTranscriber, FakeLiveResponder, MeTranscriptionSink) {
        let hub = CaptureHub(system: FakeSystemAudioCapturing(), microphone: FakeMicrophoneCapturing())
        let transcriber = FakeMeTranscriber()
        let realtime = FakeLiveResponder()
        let sink = MeTranscriptionSink(captureHub: hub, transcriber: transcriber, responder: realtime, dedupGrace: .zero)
        let controller = AnswersModeController(
            captureHub: hub,
            realtime: realtime,
            answerTrigger: FakeAnswerTriggering(),
            instructionsProvider: { "test" },
            meChannel: sink,
            isMeChannelEnabled: { enabled }
        )
        return (controller, hub, transcriber, realtime, sink)
    }

    @Test func answersAcquiresMeMicrophoneAndPassiveTearsEverythingDown() async throws {
        let (controller, hub, transcriber, _, sink) = make()
        try await controller.start()
        #expect(await hub.activeSources == [.systemAudio, .microphone])
        #expect(await hub.microphoneOptions?.sampleRate == 24_000)
        #expect(await controller.isMeChannelRunning)
        await controller.stop()
        #expect(await hub.activeSources.isEmpty)
        #expect(await transcriber.isActive == false)
        #expect(await sink.isRunning == false)
    }

    @Test func disabledMeChannelNeverTouchesMicrophone() async throws {
        let (controller, hub, transcriber, _, _) = make(enabled: false)
        try await controller.start()
        #expect(await hub.activeSources == [.systemAudio])
        #expect(await transcriber.startCount == 0)
        await controller.stop()
    }

    @Test func meChannelFailureDoesNotFailAnswers() async throws {
        let (controller, hub, transcriber, _, _) = make()
        await transcriber.setStartError(TestError(message: "offline"))
        try await controller.start()
        #expect(await hub.activeSources == [.systemAudio])
        #expect(await controller.isMeChannelRunning == false)
        await controller.stop()
    }

    @Test func meTranscriptReachesAnswersTranscriptStreamAndRemoteFeedsDedup() async throws {
        let (controller, _, transcriber, realtime, sink) = make()
        let transcripts = collectItems(controller.transcriptEvents(subscriber: "test"))
        try await controller.start()
        await realtime.emit(.transcript(TranscriptEvent(speaker: .them, itemID: "them_1", text: "Tell me about your last project", isFinal: true)))
        await settle(controller, realtime)
        await transcriber.emitFinal(itemID: "me_echo", text: "tell me about your last project")
        await transcriber.emitFinal(itemID: "me_1", text: "I built a payments platform on Kafka")
        await waitUntil { await transcripts.items.count == 2 }
        let items = await transcripts.items
        #expect(items.map(\.speaker) == [.them, .me])
        #expect(items.last?.text == "I built a payments platform on Kafka")
        #expect(await sink.droppedEchoCount == 1)
        #expect(await realtime.injectedContexts == [.me("I built a payments platform on Kafka")])
        #expect(await realtime.forceResponseCallCount == 0)
        await controller.stop()
    }
}
