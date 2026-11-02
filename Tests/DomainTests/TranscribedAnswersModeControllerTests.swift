import Foundation
import Testing
@testable import Domain

@Suite struct TranscribedAnswersModeControllerTests {
    struct Harness {
        let audio = RestartableSystemAudio()
        let recognizer: FakeSpeechRecognizer
        let generator: FakeTextAnswerGenerator
        let trigger = FakeAnswerTriggering()
        let telemetry = SessionTelemetry()
        let repository = InMemoryQuestionAnswerRepository()
        let controller: TranscribedAnswersModeController
        let events = StreamEventCollector()
        let failures = FailureCollector()

        init(texts: [String], scripts: [ScriptedAnswer] = [], triggerMode: AnswerTriggerMode = .automatic, maxPending: Int = 6) {
            recognizer = FakeSpeechRecognizer(texts: texts)
            generator = FakeTextAnswerGenerator(scripts: scripts)
            let logger = QuestionAnswerLogger(localTranscribing: FakeLocalTranscribing(), repository: repository, modelID: "whisper")
            controller = TranscribedAnswersModeController(
                systemAudio: audio,
                recognizer: recognizer,
                generator: generator,
                answerTrigger: trigger,
                settingsProvider: {
                    TranscribedAnswerSessionSettings(
                        modelID: "claude-opus-5-5",
                        systemInstructions: "SYSTEM",
                        triggerMode: triggerMode,
                        maxOutputTokens: 1024,
                        reasoningEffort: "low",
                        useServerSideFallback: false
                    )
                },
                telemetry: telemetry,
                questionAnswerLogger: logger,
                maxPendingUtterances: maxPending,
                manualFlushTimeout: .seconds(1)
            )
        }

        func start() async throws {
            await events.start(consuming: controller.streamEvents())
            await failures.start(consuming: controller.failures())
            try await controller.start()
        }

        func speak(speechMs: Int = 600, pauseMs: Int = 800) async {
            for frame in SpeechAudio.utterance(speechMs: speechMs, pauseMs: pauseMs) {
                await audio.emit(frame)
            }
        }

        func streamedTexts() async -> [String] {
            await events.events.compactMap { if case .streaming(let text) = $0 { text } else { nil } }
        }

        func completedTexts() async -> [String] {
            await events.events.compactMap { if case .completed(let text) = $0 { text } else { nil } }
        }
    }

    @Test func passiveNeverCapturesOrRecognizesUntilStarted() async {
        let harness = Harness(texts: ["Как работает индекс?"])
        #expect(await harness.audio.startCalled == false)
        #expect(await harness.recognizer.prepareCallCount == 0)
        #expect(harness.generator.requests.isEmpty)
    }

    @Test func loadsRecognitionModelBeforeStartingCapture() async throws {
        let harness = Harness(texts: [])
        try await harness.start()
        #expect(await harness.recognizer.prepareCallCount == 1)
        #expect(await harness.audio.startCalled)
        #expect(await harness.telemetry.snapshot().status == .listening)
    }

    @Test func recognitionFailureAtStartDoesNotStartCapture() async {
        let harness = Harness(texts: [])
        await harness.recognizer.setPrepareError(TestError(message: "no model"))
        await #expect(throws: TranscribedAnswersError.self) { try await harness.start() }
        #expect(await harness.audio.startCalled == false)
    }

    @Test func automaticQuestionStreamsAnswerAndClearsContextOnlyAfterCompletion() async throws {
        let harness = Harness(
            texts: ["Как бы вы спроектировали идемпотентную обработку платежей?"],
            scripts: [ScriptedAnswer(events: [.started(servedModel: "claude-opus-5-5"), .textDelta("Ключ "), .textDelta("идемпотентности."), .usage(ProviderUsage(inputTokens: 50, outputTokens: 10)), .completed(stopReason: "end_turn")], delayBetweenEvents: .milliseconds(30))]
        )
        try await harness.start()
        await harness.speak()

        #expect(await eventually { await harness.streamedTexts().contains("Ключ ") })
        #expect(await harness.controller.accumulatedTranscript.contains("идемпотентную"))
        #expect(await eventually { await harness.completedTexts() == ["Ключ идемпотентности."] })
        #expect(await harness.controller.accumulatedTranscript.isEmpty)
        #expect(harness.generator.requests.count == 1)
        #expect(harness.generator.requests.first?.trigger == .automatic)
        #expect(harness.generator.requests.first?.transcript.contains("идемпотентную") == true)
        #expect(await harness.telemetry.snapshot().usageKnown)
        #expect(await eventually { await harness.repository.saved.values.contains { $0.status == .completed && $0.modelID == "claude-opus-5-5" } })
    }

    @Test func waitSentinelIsNeverShownAndKeepsContext() async throws {
        let harness = Harness(
            texts: ["Как бы вы начали"],
            scripts: [ScriptedAnswer.text([AnswerInstructionsBuilder.waitForQuestionSentinel])]
        )
        try await harness.start()
        await harness.speak()
        #expect(await eventually { harness.generator.requests.count == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.streamedTexts().isEmpty)
        #expect(await harness.completedTexts().isEmpty)
        #expect(await harness.controller.accumulatedTranscript == "Как бы вы начали")
    }

    @Test func manualOnlyModeAccumulatesWithoutRequestsUntilTriggered() async throws {
        let harness = Harness(
            texts: ["Мы используем SQS и Lambda.", "Как бы вы обеспечили exactly-once обработку?"],
            scripts: [ScriptedAnswer.text(["Никак: только at-least-once плюс идемпотентность."])],
            triggerMode: .manualOnly
        )
        try await harness.start()
        await harness.speak()
        await harness.speak()
        #expect(await eventually { await harness.controller.accumulatedTranscript.contains("exactly-once") })
        #expect(harness.generator.requests.isEmpty)
        #expect(await eventually { await harness.telemetry.snapshot().status == .waitingForManualTrigger })

        await harness.trigger.fire()
        #expect(await eventually { await harness.completedTexts().count == 1 })
        #expect(harness.generator.requests.count == 1)
        #expect(harness.generator.requests.first?.trigger == .manual)
        #expect(harness.generator.requests.first?.transcript.contains("SQS") == true)
    }

    @Test func manualTriggerFlushesSpeechThatHasNotPausedYet() async throws {
        let harness = Harness(texts: ["Что такое CQRS"], scripts: [ScriptedAnswer.text(["Разделение чтения и записи."])], triggerMode: .manualOnly)
        try await harness.start()
        for _ in 0..<6 { await harness.audio.emit(SpeechAudio.speech(ms: 100)) }
        #expect(await eventually { await harness.controller.hasPendingSpeech })
        await harness.trigger.fire()
        #expect(await eventually { await harness.completedTexts().count == 1 })
        #expect(harness.generator.requests.first?.transcript == "Что такое CQRS")
    }

    @Test func manualTriggerWithNoSpeechReportsNoContextAndSendsNothing() async throws {
        let harness = Harness(texts: [], triggerMode: .manualOnly)
        try await harness.start()
        await harness.trigger.fire()
        #expect(await eventually { await harness.events.events.contains(.noContext) })
        #expect(harness.generator.requests.isEmpty)
    }

    @Test func manualTriggerReplacesInvisibleAutomaticRequestWithExactlyOneManual() async throws {
        let slowAutomatic = ScriptedAnswer(events: [.started(servedModel: nil), .textDelta("auto")], delayBetweenEvents: .seconds(2))
        let harness = Harness(
            texts: ["Как бы вы кешировали каталог?"],
            scripts: [slowAutomatic, ScriptedAnswer.text(["manual answer"])]
        )
        try await harness.start()
        await harness.speak()
        #expect(await eventually { harness.generator.requests.count == 1 })
        await harness.trigger.fire()
        #expect(await eventually { await harness.completedTexts() == ["manual answer"] })
        #expect(harness.generator.requests.map(\.trigger) == [.automatic, .manual])
        #expect(await eventually { harness.generator.cancelledCount == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !harness.streamedTexts().contains("auto"))
    }

    @Test func stopCancelsRequestReleasesCaptureAndDropsLateAnswer() async throws {
        let late = ScriptedAnswer(events: [.started(servedModel: nil), .textDelta("late answer"), .completed(stopReason: "end_turn")], delayBetweenEvents: .milliseconds(300), ignoresCancellation: true)
        let harness = Harness(texts: ["Как работает GC в PHP?"], scripts: [late])
        try await harness.start()
        await harness.speak()
        #expect(await eventually { harness.generator.requests.count == 1 })

        await harness.controller.stop()
        #expect(await harness.audio.stopCalled)
        #expect(await harness.audio.isCapturing == false)
        #expect(await harness.controller.accumulatedTranscript.isEmpty)
        #expect(await harness.controller.pendingUtteranceCount == 0)
        #expect(await harness.controller.isActive == false)
        #expect(await eventually { harness.generator.cancelledCount == 1 })

        try await Task.sleep(for: .milliseconds(1_200))
        #expect(await harness.streamedTexts().isEmpty)
        #expect(await harness.completedTexts().isEmpty)
        #expect(await harness.telemetry.snapshot().status == .idle)
    }

    @Test func restartAfterStopDoesNotReuseOldContext() async throws {
        let harness = Harness(texts: ["Как устроен B-tree?", "Расскажите про Redis"], scripts: [ScriptedAnswer.text(["a"]), ScriptedAnswer.text(["b"])], triggerMode: .manualOnly)
        try await harness.start()
        await harness.speak()
        #expect(await eventually { await !harness.controller.accumulatedTranscript.isEmpty })
        await harness.controller.stop()
        try await harness.controller.start()
        await harness.speak()
        #expect(await eventually { await harness.controller.accumulatedTranscript == "Расскажите про Redis" })
    }

    @Test func authenticationErrorEndsSessionWithoutClearingContext() async throws {
        let harness = Harness(texts: ["Как бы вы шардировали DynamoDB таблицу?"], scripts: [.failure(.authentication)])
        try await harness.start()
        await harness.speak()
        #expect(await eventually { await harness.failures.reasons == ["authentication"] })
        #expect(await harness.controller.accumulatedTranscript.contains("DynamoDB"))
        #expect(await harness.telemetry.snapshot().errorCounts["authentication"] == 1)
    }

    @Test func billingErrorEndsSession() async throws {
        let harness = Harness(texts: [], scripts: [.failure(.billing)], triggerMode: .manualOnly)
        await harness.recognizer.setTexts(["Почему Redis однопоточный?"])
        try await harness.start()
        await harness.speak()
        #expect(await eventually { await !harness.controller.accumulatedTranscript.isEmpty })
        await harness.trigger.fire()
        #expect(await eventually { await harness.failures.reasons == ["billing"] })
    }

    @Test func rateLimitAndNetworkErrorsKeepSessionAndAllowRetry() async throws {
        let harness = Harness(
            texts: ["Как бы вы мониторили Lambda?"],
            scripts: [.failure(.rateLimited(retryAfterSeconds: 3)), .failure(.network("timeout")), ScriptedAnswer.text(["CloudWatch метрики и алармы."])],
            triggerMode: .manualOnly
        )
        try await harness.start()
        await harness.speak()
        #expect(await eventually { await !harness.controller.accumulatedTranscript.isEmpty })
        await harness.trigger.fire()
        #expect(await eventually { await harness.telemetry.snapshot().errorCounts["rate_limited"] == 1 })
        await harness.trigger.fire()
        #expect(await eventually { await harness.telemetry.snapshot().errorCounts["network"] == 1 })
        await harness.trigger.fire()
        #expect(await eventually { await harness.completedTexts().count == 1 })
        #expect(await harness.failures.reasons.isEmpty)
        #expect(harness.generator.requests.count == 3)
    }

    @Test func recognitionErrorOnOneFragmentDoesNotStopSession() async throws {
        let harness = Harness(texts: ["Что такое outbox pattern?"], scripts: [ScriptedAnswer.text(["Запись события в той же транзакции."])])
        await harness.recognizer.setFailNextRecognition()
        try await harness.start()
        await harness.speak()
        await harness.speak()
        #expect(await eventually { await harness.completedTexts().count == 1 })
        #expect(await harness.telemetry.snapshot().errorCounts["recognition_unavailable"] == 1)
    }

    @Test func pendingRecognitionQueueIsBounded() async throws {
        let harness = Harness(texts: Array(repeating: "Фраза без вопроса.", count: 20), triggerMode: .manualOnly, maxPending: 2)
        await harness.recognizer.setRecognizeDelay(.milliseconds(400))
        try await harness.start()
        for _ in 0..<8 { await harness.speak(speechMs: 300, pauseMs: 800) }
        #expect(await harness.controller.pendingUtteranceCount <= 2)
        #expect(await eventually { await harness.controller.droppedUtteranceCount > 0 })
    }

    @Test func usageLimitWithStopPolicyEndsSessionAfterResponse() async throws {
        let harness = Harness(texts: ["Почему важен индекс?"], scripts: [ScriptedAnswer.text(["Чтобы не сканировать таблицу."], usage: ProviderUsage(inputTokens: 10_000_000, outputTokens: 10))])
        try await harness.start()
        await harness.telemetry.begin(configuration: .claudeTest(), spendPolicy: SpendPolicy(limitUSD: 0.01, mode: .stopSession))
        await harness.speak()
        #expect(await eventually { await harness.failures.reasons == ["spend_limit_reached"] })
        #expect(await harness.completedTexts().count == 1)
    }
}
