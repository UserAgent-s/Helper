import Foundation
import Testing
@testable import Domain

@Suite struct AnswersModeControllerTests {

    @Test func startRequestsStoredScope() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let hub = CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing(), scope: { .chromeOnlyPreset })
        let controller = AnswersModeController(captureHub: hub, realtime: FakeLiveResponder(), answerTrigger: FakeAnswerTriggering(), instructionsProvider: { "test" })
        try await controller.start()
        #expect(await systemAudio.requestedScopes == [.chromeOnlyPreset])
        #expect(await controller.currentEffectiveScope() == .chromeOnlyPreset)
        await controller.stop()
    }

    @Test func startWithoutStoreUsesWholeSystem() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let controller = AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: FakeLiveResponder(), answerTrigger: FakeAnswerTriggering(), instructionsProvider: { "test" })
        try await controller.start()
        #expect(await systemAudio.requestedScopes == [.defaultScope])
        await controller.stop()
    }

    @Test func fallbackNoticeDoesNotFailMode() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        await systemAudio.configureFallback(notice: .fellBackToWholeSystem(missingBundleID: "com.google.Chrome"), effectiveScope: .defaultScope)
        let hub = CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing(), scope: { .chromeOnlyPreset })
        let controller = AnswersModeController(captureHub: hub, realtime: FakeLiveResponder(), answerTrigger: FakeAnswerTriggering(), instructionsProvider: { "test" })
        let coordinator = ModeCoordinator(controllers: [.answers: controller])
        var notices = controller.captureNotices().makeAsyncIterator()

        let result = await coordinator.requestTransition(to: .answers)

        #expect(result == .succeeded(.answers))
        #expect(await notices.next() == .fellBackToWholeSystem(missingBundleID: "com.google.Chrome"))
        #expect(await controller.currentEffectiveScope() == .defaultScope)
        _ = await coordinator.requestTransition(to: .passive)
    }

    @Test func answersUsesOneSystemStreamForBothConsumers() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let hub = CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing())
        let controller = AnswersModeController(captureHub: hub, realtime: FakeLiveResponder(), answerTrigger: FakeAnswerTriggering(), instructionsProvider: { "test" })
        try await controller.start()
        #expect(await systemAudio.startCallCount == 1)
        #expect(await hub.activeSources == [.systemAudio])
        await controller.stop()
    }

    @Test func answersNeverStartsMicrophone() async throws {
        let microphone = FakeMicrophoneCapturing()
        let hub = CaptureHub(system: FakeSystemAudioCapturing(), microphone: microphone)
        let controller = AnswersModeController(captureHub: hub, realtime: FakeLiveResponder(), answerTrigger: FakeAnswerTriggering(), instructionsProvider: { "test" })
        try await controller.start()
        #expect(await microphone.startCalled == false)
        await controller.stop()
    }

    @Test func passiveTearsDownCaptureNetworkAndWrites() async throws {
        let answersSystemAudio = FakeSystemAudioCapturing()
        let answersHub = CaptureHub(system: answersSystemAudio, microphone: FakeMicrophoneCapturing())
        let realtime = FakeLiveResponder()
        let answers = AnswersModeController(captureHub: answersHub, realtime: realtime, answerTrigger: FakeAnswerTriggering(), instructionsProvider: { "test" })
        let answersCoordinator = ModeCoordinator(controllers: [.answers: answers])

        _ = await answersCoordinator.requestTransition(to: .answers)
        #expect(await answersHub.activeSources == [.systemAudio])
        _ = await answersCoordinator.requestTransition(to: .passive)

        #expect(await answersHub.activeSources.isEmpty)
        #expect(await realtime.stopCallCount == 1)
        #expect(await answersSystemAudio.stopCalled)

        let recordingSystemAudio = FakeSystemAudioCapturing()
        let microphone = FakeMicrophoneCapturing()
        let recordingHub = CaptureHub(system: recordingSystemAudio, microphone: microphone)
        let audioRecording = FakeMeetingAudioRecording()
        let recording = RecordingModeController(
            captureHub: recordingHub, transcribing: FakeLocalTranscribing(), repository: FakeMeetingRepository(),
            audioRecording: audioRecording, isAudioStorageEnabled: { true }, chunkDurationSeconds: 3600
        )
        let recordingCoordinator = ModeCoordinator(controllers: [.recording: recording])

        _ = await recordingCoordinator.requestTransition(to: .recording)
        #expect(await recordingHub.activeSources == [.systemAudio, .microphone])
        _ = await recordingCoordinator.requestTransition(to: .passive)

        #expect(await recordingHub.activeSources.isEmpty)
        #expect(await audioRecording.finishCallCount == 1)
        #expect(await recordingSystemAudio.stopCalled)
        #expect(await microphone.stopCalled)
    }

    @Test func recordingNeverCallsRealtime() async throws {
        let hub = CaptureHub(system: FakeSystemAudioCapturing(), microphone: FakeMicrophoneCapturing())
        let realtime = FakeLiveResponder()
        let answers = AnswersModeController(captureHub: hub, realtime: realtime, answerTrigger: FakeAnswerTriggering(), instructionsProvider: { "test" })
        let recording = RecordingModeController(captureHub: hub, transcribing: FakeLocalTranscribing(), repository: FakeMeetingRepository(), chunkDurationSeconds: 3600)
        let coordinator = ModeCoordinator(controllers: [.answers: answers, .recording: recording])

        _ = await coordinator.requestTransition(to: .recording)
        _ = await coordinator.requestTransition(to: .passive)

        #expect(await realtime.startCalled == false)
        #expect(await realtime.appendedFrameCount == 0)
    }

    @Test func exactlyOneVisibleAnswerWhenManualRacesAutomatic() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

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
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

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
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

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
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

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
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

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
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

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
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        await realtime.setForceResponseError(TestError(message: "no_context"))
        let controller = AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

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
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

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
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

        try await controller.start()
        await controller.stop()

        #expect(await systemAudio.stopCalled)
        #expect(await realtime.stopCalled)
    }

    @Test func sentinelDoesNotCreateQuestionAnswerRecord() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")
        let controller = AnswersModeController(
            captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" },
            questionAnswerLogger: logger
        )

        try await controller.start()
        await realtime.emit(.waitingForQuestion)
        try await Task.sleep(for: .milliseconds(30))

        #expect(await repository.savedPairs.isEmpty)

        await controller.stop()
    }

    @Test func firstDeltaLogsAutomaticAnswerWithRealtimeQuestionText() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")
        let controller = AnswersModeController(
            captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" },
            questionAnswerLogger: logger
        )

        try await controller.start()
        await systemAudio.emit(PCMAudioFrame(samples: [1, 2, 3], sampleRate: 16000, channelCount: 1, capturedAt: Date(), source: .systemAudio))
        try await Task.sleep(for: .milliseconds(20))

        await realtime.emit(.transcript(TranscriptEvent(speaker: .them, itemID: "u1", text: "Что такое", isFinal: false)))
        await realtime.emit(.transcript(TranscriptEvent(speaker: .them, itemID: "u1", text: "Что такое идемпотентность?", language: "ru", isFinal: true)))
        await realtime.emit(.questionContext(responseID: "auto-1", itemIDs: ["u1"]))
        await realtime.emit(.responseStarted(responseID: "auto-1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "auto-1", text: "Первый"))
        await realtime.emit(.textDelta(responseID: "auto-1", text: " кусок"))
        await realtime.emit(.completed(responseID: "auto-1"))
        try await Task.sleep(for: .milliseconds(30))
        await logger.flush()

        let saved = await repository.latest(responseID: "auto-1")
        #expect(saved?.triggerKind == .automatic)
        #expect(saved?.answerText == "Первый кусок")
        #expect(saved?.status == .completed)
        #expect(saved?.questionText == "Что такое идемпотентность?")
        #expect(saved?.questionTranscriptionStatus == .completed)

        await controller.stop()
    }

    @Test func transcriptEventsAreForwardedAndUnrecognizedQuestionIsMarked() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")
        let controller = AnswersModeController(
            captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: FakeAnswerTriggering(), instructionsProvider: { "test" },
            questionAnswerLogger: logger
        )
        let transcripts = controller.transcriptEvents(subscriber: "test")
        let received = Task { () -> [TranscriptEvent] in
            var collected: [TranscriptEvent] = []
            for await event in transcripts {
                collected.append(event)
                if collected.count == 2 { break }
            }
            return collected
        }

        try await controller.start()
        await realtime.emit(.transcript(TranscriptEvent(speaker: .them, itemID: "u1", text: "При", isFinal: false)))
        await realtime.emit(.transcript(TranscriptEvent(speaker: .them, itemID: "u1", text: "Привет", isFinal: true)))
        await realtime.emit(.questionContext(responseID: "r1", itemIDs: []))
        await realtime.emit(.responseStarted(responseID: "r1", trigger: .manual))
        await realtime.emit(.textDelta(responseID: "r1", text: "Ответ"))
        try await Task.sleep(for: .milliseconds(30))
        await logger.flush()

        #expect(await received.value.map(\.isFinal) == [false, true])
        #expect(await repository.latest(responseID: "r1")?.questionTranscriptionStatus == .failed)
        await controller.stop()
    }

    @Test func capturedFramesRecordCallbackToSendLatency() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let latency = FakeLatencyRecording()
        let controller = AnswersModeController(
            captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" },
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
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let latency = FakeLatencyRecording()
        let controller = AnswersModeController(
            captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" },
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
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")
        let controller = AnswersModeController(
            captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" },
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
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

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
        let realtime = FakeLiveResponder()
        let trigger = FakeAnswerTriggering()
        let controller = AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: FakeMicrophoneCapturing()), realtime: realtime, answerTrigger: trigger, instructionsProvider: { "test" })

        let collector = FailureCollector()
        await collector.start(consuming: controller.failures())

        try await controller.start()
        await controller.stop()
        try await Task.sleep(for: .milliseconds(30))

        #expect(await collector.reasons.isEmpty)
    }
}
