import Foundation
import Testing
@testable import Domain

@Suite struct AnswersScenarioTests {

    private func makeController(
        systemAudio: FakeSystemAudioCapturing,
        realtime: FakeRealtimeAnswering,
        trigger: FakeAnswerTriggering
    ) -> AnswersModeController {
        AnswersModeController(systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })
    }

    @Test func shortQuestionProducesOneVisibleAnswer() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)

        try await controller.start()
        for frame in SyntheticAudioFixtures.toneBurst(durationMs: 400) {
            await systemAudio.emit(frame)
        }
        await realtime.emit(.responseStarted(responseID: "r1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r1", text: "Ответ."))
        await realtime.emit(.completed(responseID: "r1"))
        try await Task.sleep(for: .milliseconds(30))

        #expect(await controller.turnPhase == .completed)
        await controller.stop()
    }

    @Test func statementWithoutQuestionWaitsWithoutStartingResponse() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)

        try await controller.start()
        for frame in SyntheticAudioFixtures.toneBurst(durationMs: 600) {
            await systemAudio.emit(frame)
        }
        await realtime.emit(.waitingForQuestion)
        try await Task.sleep(for: .milliseconds(20))

        #expect(await controller.turnPhase == .collectingContext)
        #expect(await controller.activeResponseID == nil)
        await controller.stop()
    }

    @Test func threeTurnExplanationThenQuestionAccumulatesFullContextSnapshot() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test")
        let controller = AnswersModeController(
            systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" },
            questionAnswerLogger: logger
        )

        try await controller.start()
        let turns = SyntheticAudioFixtures.explanationThenPauseThenQuestion(turnDurationsMs: [300, 300, 300], pauseMs: 100)
        for frame in turns {
            await systemAudio.emit(frame)
        }
        try await Task.sleep(for: .milliseconds(20))
        await realtime.emit(.responseStarted(responseID: "r1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r1", text: "Ответ."))
        try await Task.sleep(for: .milliseconds(30))

        #expect(await transcribing.transcribeCallCount == 1)
        #expect(await transcribing.receivedFrameBatches.first?.count == turns.count)

        await controller.stop()
    }

    @Test func rhetoricalQuestionThenContinuedExplanationThenRealQuestionYieldsOneAnswer() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)

        try await controller.start()
        await realtime.emit(.waitingForQuestion)
        await realtime.emit(.waitingForQuestion)
        await realtime.emit(.responseStarted(responseID: "r1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r1", text: "Финальный ответ."))
        await realtime.emit(.completed(responseID: "r1"))
        try await Task.sleep(for: .milliseconds(30))

        #expect(await controller.turnPhase == .completed)
        await controller.stop()
    }

    @Test func sentinelMisclassifiedThenManualTriggerForcesResponse() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)

        try await controller.start()
        await realtime.emit(.waitingForQuestion)
        try await Task.sleep(for: .milliseconds(10))
        await trigger.fire()
        try await Task.sleep(for: .milliseconds(20))

        #expect(await realtime.forceResponseCallCount == 1)
        await controller.stop()
    }

    @Test func pauseInsideQuestionDoesNotSplitContextWindow() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test")
        let controller = AnswersModeController(
            systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" },
            questionAnswerLogger: logger
        )

        try await controller.start()
        let frames = SyntheticAudioFixtures.toneBurst(durationMs: 200) + SyntheticAudioFixtures.silence(durationMs: 300) + SyntheticAudioFixtures.toneBurst(durationMs: 200)
        for frame in frames { await systemAudio.emit(frame) }
        try await Task.sleep(for: .milliseconds(20))
        await realtime.emit(.responseStarted(responseID: "r1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r1", text: "Ответ."))
        try await Task.sleep(for: .milliseconds(30))

        #expect(await transcribing.receivedFrameBatches.first?.count == frames.count)
        await controller.stop()
    }

    @Test func twoQuestionsInARowEachGetOwnAnswerAndFreshWindow() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)

        try await controller.start()
        await realtime.emit(.responseStarted(responseID: "r1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r1", text: "Первый ответ."))
        await realtime.emit(.completed(responseID: "r1"))
        try await Task.sleep(for: .milliseconds(20))

        await realtime.emit(.responseStarted(responseID: "r2", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r2", text: "Второй ответ."))
        await realtime.emit(.completed(responseID: "r2"))
        try await Task.sleep(for: .milliseconds(20))

        #expect(await controller.turnPhase == .completed)
        #expect(await controller.activeResponseID == nil)
        await controller.stop()
    }

    @Test func russianAndEnglishTextBothFlowThroughStreamingUnmodified() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)
        let collector = StreamEventCollector()
        await collector.start(consuming: controller.streamEvents())

        try await controller.start()
        await realtime.emit(.responseStarted(responseID: "r1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r1", text: "Ответ на русском языке."))
        await realtime.emit(.completed(responseID: "r1"))
        try await Task.sleep(for: .milliseconds(20))

        await realtime.emit(.responseStarted(responseID: "r2", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "r2", text: "Answer in English."))
        await realtime.emit(.completed(responseID: "r2"))
        try await Task.sleep(for: .milliseconds(20))

        let events = await collector.events
        #expect(events.contains(.completed(finalText: "Ответ на русском языке.")))
        #expect(events.contains(.completed(finalText: "Answer in English.")))
        await controller.stop()
    }

    @Test func backgroundNoiseFramesAreForwardedWithoutSpecialHandling() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = makeController(systemAudio: systemAudio, realtime: realtime, trigger: trigger)

        try await controller.start()
        for frame in SyntheticAudioFixtures.backgroundNoise(durationMs: 200) {
            await systemAudio.emit(frame)
        }
        try await Task.sleep(for: .milliseconds(20))

        #expect(await realtime.appendedFrameCount == 10)
        await controller.stop()
    }

    @Test func sourceStreamDropMidSessionLeavesControllerStoppable() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
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
