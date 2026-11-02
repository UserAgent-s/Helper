import Foundation
import Testing
@testable import Domain

@Suite struct QuestionAnswerLoggerTests {

    @Test func whisperNotCalledBeforeBeginDraft() async {
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        _ = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, modelID: "test-model")

        #expect(await transcribing.transcribeCallCount == 0)
        #expect(await repository.savedPairs.isEmpty)
    }

    @Test func beginDraftPersistsAnswerStreamingBeforeTranscriptionResolves() async throws {
        let transcribing = FakeLocalTranscribing()
        await transcribing.setDelay(.milliseconds(200))
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, modelID: "test-model")

        await logger.beginDraft(
            responseID: "r1",
            triggerKind: .automatic,
            sourceAppBundleID: "com.example.meet",
            contextWindowStartedAt: Date(),
            contextSnapshot: []
        )
        try await Task.sleep(for: .milliseconds(30))
        await logger.flushPersistence()

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.status == .answerStreaming)
        #expect(saved?.questionText == nil)
    }

    @Test func multipleContextSegmentsPassedAsOneSnapshot() async throws {
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, modelID: "test-model")

        let frames = (0..<3).map { index in
            PCMAudioFrame(samples: [Int16(index)], sampleRate: 16000, channelCount: 1, capturedAt: Date(), source: .systemAudio)
        }

        await logger.beginDraft(
            responseID: "r1",
            triggerKind: .automatic,
            sourceAppBundleID: nil,
            contextWindowStartedAt: Date(),
            contextSnapshot: frames
        )
        try await Task.sleep(for: .milliseconds(30))
        await logger.flushPersistence()

        #expect(await transcribing.transcribeCallCount == 1)
        #expect(await transcribing.receivedFrameBatches.first?.count == 3)
    }

    @Test func manualTriggerCreatesRecordWithManualKind() async throws {
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, modelID: "test-model")

        await logger.beginDraft(
            responseID: "r1",
            triggerKind: .manual,
            sourceAppBundleID: nil,
            contextWindowStartedAt: Date(),
            contextSnapshot: []
        )
        try await Task.sleep(for: .milliseconds(20))

        #expect(await repository.latest(responseID: "r1")?.triggerKind == .manual)
    }

    @Test func answerSavedEvenWhileQuestionStillTranscribing() async throws {
        let transcribing = FakeLocalTranscribing()
        await transcribing.setDelay(.milliseconds(200))
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, modelID: "test-model")

        await logger.beginDraft(
            responseID: "r1",
            triggerKind: .automatic,
            sourceAppBundleID: nil,
            contextWindowStartedAt: Date(),
            contextSnapshot: []
        )
        await logger.recordCompleted(responseID: "r1", finalText: "Готовый ответ", responseTotalMs: 850)
        try await Task.sleep(for: .milliseconds(30))
        await logger.flushPersistence()

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.answerText == "Готовый ответ")
        #expect(saved?.status == .completed)
        #expect(saved?.questionText == nil)
    }

    @Test func lateTranscriptionUpdatesCorrectUUID() async throws {
        let transcribing = ScriptedLocalTranscribing()
        await transcribing.setResult([TranscribedSegment(text: "Вопрос A", startMs: 0, endMs: 500, source: .local)], forFirstSample: 1)
        await transcribing.setResult([TranscribedSegment(text: "Вопрос B", startMs: 0, endMs: 500, source: .local)], forFirstSample: 2)
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, modelID: "test-model")

        let frameA = PCMAudioFrame(samples: [1], sampleRate: 16000, channelCount: 1, capturedAt: Date(), source: .systemAudio)
        let frameB = PCMAudioFrame(samples: [2], sampleRate: 16000, channelCount: 1, capturedAt: Date(), source: .systemAudio)

        await logger.beginDraft(responseID: "r-a", triggerKind: .automatic, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [frameA])
        await logger.beginDraft(responseID: "r-b", triggerKind: .automatic, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [frameB])
        _ = await eventually {
            let a = await repository.latest(responseID: "r-a")?.questionText
            let b = await repository.latest(responseID: "r-b")?.questionText
            return a != nil && b != nil
        }

        let pairA = await repository.latest(responseID: "r-a")
        let pairB = await repository.latest(responseID: "r-b")
        #expect(pairA?.questionText == "Вопрос A")
        #expect(pairB?.questionText == "Вопрос B")
        #expect(pairA?.id != pairB?.id)
    }

    @Test func transcriptionFailureSavesStatusFailedWithoutFabricatedQuestion() async throws {
        let transcribing = FakeLocalTranscribing()
        await transcribing.setError(TestError(message: "whisper_unavailable"))
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, modelID: "test-model")

        await logger.beginDraft(responseID: "r1", triggerKind: .automatic, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [])
        _ = await eventually { await repository.latest(responseID: "r1")?.questionTranscriptionStatus == .failed }

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.questionTranscriptionStatus == .failed)
        #expect(saved?.questionText == nil)
    }

    @Test func transcriptionTimeoutSavesStatusFailed() async throws {
        let transcribing = FakeLocalTranscribing()
        await transcribing.setDelay(.milliseconds(200))
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, modelID: "test-model", whisperTimeout: .milliseconds(20))

        await logger.beginDraft(responseID: "r1", triggerKind: .automatic, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [])
        _ = await eventually(timeout: .seconds(2)) { await repository.latest(responseID: "r1")?.questionTranscriptionStatus == .failed }

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.questionTranscriptionStatus == .failed)
    }

    @Test func recordCancelledMarksStatusCancelled() async throws {
        let transcribing = FakeLocalTranscribing()
        await transcribing.setDelay(.milliseconds(200))
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, modelID: "test-model")

        await logger.beginDraft(responseID: "r1", triggerKind: .automatic, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [])
        await logger.recordCancelled(responseID: "r1")
        try await Task.sleep(for: .milliseconds(20))

        #expect(await repository.latest(responseID: "r1")?.status == .cancelled)
    }

    @Test func discardBeforeValidAnswerNeverPersistsAnything() async throws {
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, modelID: "test-model")

        await logger.discardBeforeValidAnswer(responseID: "never-started")
        await logger.recordCompleted(responseID: "never-started", finalText: "should not persist", responseTotalMs: nil)
        try await Task.sleep(for: .milliseconds(20))

        #expect(await repository.savedPairs.isEmpty)
        #expect(await transcribing.transcribeCallCount == 0)
    }

    @Test func twoConcurrentDraftsDoNotMix() async throws {
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, modelID: "test-model")

        await logger.beginDraft(responseID: "r1", triggerKind: .automatic, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [])
        await logger.beginDraft(responseID: "r2", triggerKind: .manual, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [])
        await logger.recordCompleted(responseID: "r1", finalText: "Ответ один", responseTotalMs: 100)
        await logger.recordCompleted(responseID: "r2", finalText: "Ответ два", responseTotalMs: 200)
        try await Task.sleep(for: .milliseconds(30))
        await logger.flushPersistence()

        let pair1 = await repository.latest(responseID: "r1")
        let pair2 = await repository.latest(responseID: "r2")
        #expect(pair1?.answerText == "Ответ один")
        #expect(pair1?.triggerKind == .automatic)
        #expect(pair2?.answerText == "Ответ два")
        #expect(pair2?.triggerKind == .manual)
    }
}
