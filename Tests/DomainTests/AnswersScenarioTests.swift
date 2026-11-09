import Foundation
import Testing
@testable import Domain

@Suite struct AnswersScenarioTests {

    private func makeController(
        systemAudio: FakeSystemAudioCapturing,
        realtime: FakeLiveResponder,
        trigger: FakeAnswerTriggering
    ) -> AnswersModeController {
        AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })
    }

    @Test func shortQuestionProducesOneVisibleAnswer() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)

        try await controller.start()
        for frame in SyntheticAudioFixtures.toneBurst(durationMs: 400) {
            await systemAudio.emit(frame)
        }
        await realtime.emit(.responseStarted(responseID: "r1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r1", text: "Ответ."))
        await realtime.emit(.completed(responseID: "r1"))
        await settle(controller, realtime)

        #expect(await controller.turnPhase == .completed)
        await controller.stop()
    }

    @Test func statementWithoutQuestionWaitsWithoutStartingResponse() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)

        try await controller.start()
        for frame in SyntheticAudioFixtures.toneBurst(durationMs: 600) {
            await systemAudio.emit(frame)
        }
        await realtime.emit(.waitingForQuestion)
        await settle(controller, realtime)

        #expect(await controller.turnPhase == .collectingContext)
        #expect(await controller.activeResponseID == nil)
        await controller.stop()
    }

    @Test func threeTurnExplanationThenQuestionJoinsAllRealtimeTranscripts() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test")
        let controller = AnswersModeController(
            captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" },
            questionAnswerLogger: logger
        )

        try await controller.start()
        for (index, text) in ["Мы строим платёжный шлюз.", "Нагрузка десять тысяч RPS.", "Как бы вы спроектировали ретраи?"].enumerated() {
            await realtime.emit(.transcript(TranscriptEvent(speaker: .them, itemID: "u\(index)", text: text, isFinal: true)))
        }
        await realtime.emit(.questionContext(responseID: "r1", itemIDs: ["u0", "u1", "u2"]))
        await realtime.emit(.responseStarted(responseID: "r1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r1", text: "Ответ."))
        await settle(controller, realtime)
        await logger.flush()

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.questionText == "Мы строим платёжный шлюз. Нагрузка десять тысяч RPS. Как бы вы спроектировали ретраи?")
        #expect(saved?.questionTranscriptionStatus == .completed)

        await controller.stop()
    }

    @Test func rhetoricalQuestionThenContinuedExplanationThenRealQuestionYieldsOneAnswer() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)

        try await controller.start()
        await realtime.emit(.waitingForQuestion)
        await realtime.emit(.waitingForQuestion)
        await realtime.emit(.responseStarted(responseID: "r1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r1", text: "Финальный ответ."))
        await realtime.emit(.completed(responseID: "r1"))
        await settle(controller, realtime)

        #expect(await controller.turnPhase == .completed)
        await controller.stop()
    }

    @Test func sentinelMisclassifiedThenManualTriggerForcesResponse() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)

        try await controller.start()
        await realtime.emit(.waitingForQuestion)
        await settle(controller, realtime)
        await trigger.fire()
        await waitUntil { await realtime.forceResponseCallCount == 1 }

        #expect(await realtime.forceResponseCallCount == 1)
        await controller.stop()
    }

    @Test func pauseInsideQuestionKeepsBothTranscriptItemsInOneQuestion() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test")
        let controller = AnswersModeController(
            captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" },
            questionAnswerLogger: logger
        )

        try await controller.start()
        await realtime.emit(.questionContext(responseID: "r1", itemIDs: ["a", "b"]))
        await realtime.emit(.responseStarted(responseID: "r1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r1", text: "Ответ."))
        await realtime.emit(.transcript(TranscriptEvent(speaker: .them, itemID: "b", text: "про индексы?", isFinal: true)))
        await realtime.emit(.transcript(TranscriptEvent(speaker: .them, itemID: "a", text: "А что вы думаете", isFinal: true)))
        await settle(controller, realtime)
        await logger.flush()

        #expect(await repository.latest(responseID: "r1")?.questionText == "А что вы думаете про индексы?")
        await controller.stop()
    }

    @Test func twoQuestionsInARowEachGetOwnAnswerAndFreshWindow() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)

        try await controller.start()
        await realtime.emit(.responseStarted(responseID: "r1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r1", text: "Первый ответ."))
        await realtime.emit(.completed(responseID: "r1"))
        await settle(controller, realtime)

        await realtime.emit(.responseStarted(responseID: "r2", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r2", text: "Второй ответ."))
        await realtime.emit(.completed(responseID: "r2"))
        await settle(controller, realtime)

        #expect(await controller.turnPhase == .completed)
        #expect(await controller.activeResponseID == nil)
        await controller.stop()
    }

    @Test func russianAndEnglishTextBothFlowThroughStreamingUnmodified() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)
        let collector = StreamEventCollector()
        await collector.start(consuming: controller.streamEvents())

        try await controller.start()
        await realtime.emit(.responseStarted(responseID: "r1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r1", text: "Ответ на русском языке."))
        await realtime.emit(.completed(responseID: "r1"))
        await settle(controller, realtime)

        await realtime.emit(.responseStarted(responseID: "r2", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r2", text: "Answer in English."))
        await realtime.emit(.completed(responseID: "r2"))
        await settle(controller, realtime)
        await waitUntil { await collector.events.contains(.completed(finalText: "Answer in English.")) }

        let events = await collector.events
        #expect(events.contains(.completed(finalText: "Ответ на русском языке.")))
        #expect(events.contains(.completed(finalText: "Answer in English.")))
        await controller.stop()
    }

    @Test func backgroundNoiseFramesAreForwardedWithoutSpecialHandling() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)

        try await controller.start()
        for frame in SyntheticAudioFixtures.backgroundNoise(durationMs: 200) {
            await systemAudio.emit(frame)
        }
        await waitUntil { await realtime.appendedFrameCount == 10 }

        #expect(await realtime.appendedFrameCount == 10)
        await controller.stop()
    }

    @Test func sourceStreamDropMidSessionLeavesControllerStoppable() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)

        try await controller.start()
        await systemAudio.emit(SyntheticAudioFixtures.toneBurst(durationMs: 20).first!)
        await systemAudio.stop()
        try await Task.sleep(for: .milliseconds(20))

        await controller.stop()
        #expect(await controller.turnPhase == .collectingContext)
    }
}
