import Foundation
import Testing
@testable import Domain

@Suite struct AnswersModeControllerTests {

    @Test func exactlyOneVisibleAnswerWhenManualRacesAutomatic() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

        try await controller.start()

        await trigger.fire()
        try await Task.sleep(for: .milliseconds(30))

        await realtime.emit(.responseStarted(responseID: "auto-1", trigger: .automatic))
        await realtime.emit(.responseStarted(responseID: "manual-1", trigger: .manual))
        await realtime.emit(.textDelta(responseID: "auto-1", text: "Ответ"))
        await realtime.emit(.textDelta(responseID: "manual-1", text: "Другой ответ"))
        await realtime.emit(.completed(responseID: "auto-1"))
        await realtime.emit(.completed(responseID: "manual-1"))

        try await Task.sleep(for: .milliseconds(30))

        #expect(await controller.turnPhase == .completed)
        #expect(await controller.activeResponseID == nil)

        #expect(await realtime.forceResponseCallCount == 1)

        await controller.stop()
    }

    @Test func manualTriggerIgnoredWhileAlreadyStreaming() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

        try await controller.start()

        await realtime.emit(.responseStarted(responseID: "auto-1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "auto-1", text: "..."))
        try await Task.sleep(for: .milliseconds(20))

        await trigger.fire()
        try await Task.sleep(for: .milliseconds(20))

        #expect(await realtime.forceResponseCallCount == 0)

        await controller.stop()
    }

    @Test func manualTriggerCancelledOnModeExit() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

        try await controller.start()
        await trigger.fire()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await realtime.forceResponseCallCount == 1)

        await controller.stop()
        #expect(await controller.turnPhase == .collectingContext)

        await trigger.fire()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await realtime.forceResponseCallCount == 1)
    }

    @Test func manualTriggerWorksAfterCompletedAnswerWithoutWaitingForQuestionEvent() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

        try await controller.start()

        await realtime.emit(.responseStarted(responseID: "auto-1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "auto-1", text: "Ответ"))
        await realtime.emit(.completed(responseID: "auto-1"))
        try await Task.sleep(for: .milliseconds(20))

        #expect(await controller.turnPhase == .completed)

        await trigger.fire()
        try await Task.sleep(for: .milliseconds(20))

        #expect(await realtime.forceResponseCallCount == 1)

        await controller.stop()
    }

    @Test func waitingForQuestionDoesNotStartAResponse() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

        try await controller.start()
        await realtime.emit(.waitingForQuestion)
        await realtime.emit(.waitingForQuestion)
        try await Task.sleep(for: .milliseconds(20))

        #expect(await controller.turnPhase == .collectingContext)
        #expect(await controller.activeResponseID == nil)

        await controller.stop()
    }

    @Test func streamEventsCarryAccumulatedTextAndCompletion() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

        let collector = StreamEventCollector()
        await collector.start(consuming: controller.streamEvents())

        try await controller.start()
        await realtime.emit(.responseStarted(responseID: "auto-1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "auto-1", text: "Прямой"))
        await realtime.emit(.textDelta(responseID: "auto-1", text: " ответ."))
        await realtime.emit(.completed(responseID: "auto-1"))
        try await Task.sleep(for: .milliseconds(30))

        let events = await collector.events
        #expect(events.contains(.streaming(text: "Прямой")))
        #expect(events.contains(.streaming(text: "Прямой ответ.")))
        #expect(events.contains(.completed(finalText: "Прямой ответ.")))

        await controller.stop()
    }

    @Test func noContextEmittedWhenManualTriggerRejected() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        await realtime.setForceResponseError(TestError(message: "no_context"))
        let controller = AnswersModeController(systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

        let collector = StreamEventCollector()
        await collector.start(consuming: controller.streamEvents())

        try await controller.start()
        await trigger.fire()
        try await Task.sleep(for: .milliseconds(30))

        let events = await collector.events
        #expect(events.contains(.manualResponsePending))
        #expect(events.contains(.noContext))
        #expect(await controller.turnPhase == .collectingContext)

        await controller.stop()
    }

    @Test func cancelledStreamEventClearsAccumulatedText() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

        let collector = StreamEventCollector()
        await collector.start(consuming: controller.streamEvents())

        try await controller.start()
        await realtime.emit(.responseStarted(responseID: "auto-1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "auto-1", text: "Начало"))
        await realtime.emit(.cancelled(responseID: "auto-1", reason: "interrupted_by_speech"))
        try await Task.sleep(for: .milliseconds(30))

        let events = await collector.events
        #expect(events.contains(.cancelled))
        #expect(!events.contains { if case .completed = $0 { true } else { false } })

        await controller.stop()
    }

    @Test func stopReleasesCaptureAndRealtimeResources() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

        try await controller.start()
        await controller.stop()

        #expect(await systemAudio.stopCalled)
        #expect(await realtime.stopCalled)
    }

    @Test func sentinelDoesNotCreateQuestionAnswerRecord() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model")
        let controller = AnswersModeController(
            systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" },
            questionAnswerLogger: logger
        )

        try await controller.start()
        await realtime.emit(.waitingForQuestion)
        try await Task.sleep(for: .milliseconds(30))

        #expect(await repository.savedPairs.isEmpty)
        #expect(await transcribing.transcribeCallCount == 0)

        await controller.stop()
    }

    @Test func firstDeltaLogsAutomaticAnswerWithContextSnapshot() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model")
        let controller = AnswersModeController(
            systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" },
            questionAnswerLogger: logger
        )

        try await controller.start()
        await systemAudio.emit(PCMAudioFrame(samples: [1, 2, 3], sampleRate: 16000, channelCount: 1, capturedAt: Date(), source: .systemAudio))
        try await Task.sleep(for: .milliseconds(20))

        await realtime.emit(.responseStarted(responseID: "auto-1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "auto-1", text: "Первый"))
        await realtime.emit(.textDelta(responseID: "auto-1", text: " кусок"))
        await realtime.emit(.completed(responseID: "auto-1"))
        try await Task.sleep(for: .milliseconds(30))

        #expect(await transcribing.transcribeCallCount == 1)
        #expect(await transcribing.receivedFrameBatches.first?.count == 1)
        let saved = await repository.latest(responseID: "auto-1")
        #expect(saved?.triggerKind == .automatic)
        #expect(saved?.answerText == "Первый кусок")
        #expect(saved?.status == .completed)

        await controller.stop()
    }

    @Test func capturedFramesRecordCallbackToSendLatency() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let latency = FakeLatencyRecording()
        let controller = AnswersModeController(
            systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" },
            latencyRecording: latency
        )

        try await controller.start()
        await systemAudio.emit(PCMAudioFrame(samples: [1], sampleRate: 16000, channelCount: 1, capturedAt: Date(), source: .systemAudio))
        try await Task.sleep(for: .milliseconds(20))

        let recorded = await latency.recordedMetrics
        #expect(recorded.contains { if case .captureCallbackToSendMs = $0 { true } else { false } })

        await controller.stop()
    }

    @Test func firstDeltaRecordsFirstPaintLatencyWithoutArtificialDebounce() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let latency = FakeLatencyRecording()
        let controller = AnswersModeController(
            systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" },
            latencyRecording: latency
        )

        try await controller.start()
        await realtime.emit(.responseStarted(responseID: "auto-1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "auto-1", text: "Первый"))
        await realtime.emit(.textDelta(responseID: "auto-1", text: " второй"))
        try await Task.sleep(for: .milliseconds(20))

        let recorded = await latency.recordedMetrics
        let paintMetrics = recorded.compactMap { metric -> Int? in
            if case .firstDeltaToFirstPaintMs(let value) = metric { value } else { nil }
        }
        #expect(paintMetrics.count == 1)
        #expect(paintMetrics.first! < 50)

        await controller.stop()
    }

    @Test func manualTriggerLogsManualAnswer() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model")
        let controller = AnswersModeController(
            systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" },
            questionAnswerLogger: logger
        )

        try await controller.start()
        await trigger.fire()
        try await Task.sleep(for: .milliseconds(20))
        await realtime.emit(.responseStarted(responseID: "manual-1", trigger: .manual))
        await realtime.emit(.textDelta(responseID: "manual-1", text: "Ответ сейчас"))
        await realtime.emit(.completed(responseID: "manual-1"))
        try await Task.sleep(for: .milliseconds(30))

        #expect(await repository.latest(responseID: "manual-1")?.triggerKind == .manual)

        await controller.stop()
    }

    @Test func unexpectedCaptureStreamEndReportsFailureRatherThanGoingSilent() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

        let collector = FailureCollector()
        await collector.start(consuming: controller.failures())

        try await controller.start()
        await systemAudio.simulateUnexpectedEnd()
        try await Task.sleep(for: .milliseconds(30))

        #expect(await collector.reasons == ["system_audio_capture_ended"])

        await controller.stop()
    }

    @Test func intentionalStopDoesNotReportCaptureFailure() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeRealtimeAnswering()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(systemAudio: systemAudio, realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

        let collector = FailureCollector()
        await collector.start(consuming: controller.failures())

        try await controller.start()
        await controller.stop()
        try await Task.sleep(for: .milliseconds(30))

        #expect(await collector.reasons.isEmpty)
    }
}
