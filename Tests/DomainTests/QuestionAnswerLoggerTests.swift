import Foundation
import Testing
@testable import Domain

@Suite struct QuestionAnswerLoggerTests {

    @Test func whisperNotCalledBeforeBeginDraft() async {
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        _ = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model")

        #expect(await transcribing.transcribeCallCount == 0)
        #expect(await repository.savedPairs.isEmpty)
    }

    @Test func beginDraftPersistsAnswerStreamingBeforeTranscriptionResolves() async throws {
        let transcribing = FakeLocalTranscribing()
        await transcribing.setDelay(.milliseconds(200))
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model")

        await logger.beginDraft(
            responseID: "r1",
            triggerKind: .automatic,
            sourceAppBundleID: "com.example.meet",
            contextWindowStartedAt: Date(),
            contextSnapshot: []
        )
        try await Task.sleep(for: .milliseconds(30))

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.status == .answerStreaming)
        #expect(saved?.questionText == nil)
    }

    @Test func multipleContextSegmentsPassedAsOneSnapshot() async throws {
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model")

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

        #expect(await transcribing.transcribeCallCount == 1)
        #expect(await transcribing.receivedFrameBatches.first?.count == 3)
    }

    @Test func manualTriggerCreatesRecordWithManualKind() async throws {
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model")

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
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model")

        await logger.beginDraft(
            responseID: "r1",
            triggerKind: .automatic,
            sourceAppBundleID: nil,
            contextWindowStartedAt: Date(),
            contextSnapshot: []
        )
        await logger.recordCompleted(responseID: "r1", finalText: "Готовый ответ", responseTotalMs: 850)
        try await Task.sleep(for: .milliseconds(30))

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
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model")

        let frameA = PCMAudioFrame(samples: [1], sampleRate: 16000, channelCount: 1, capturedAt: Date(), source: .systemAudio)
        let frameB = PCMAudioFrame(samples: [2], sampleRate: 16000, channelCount: 1, capturedAt: Date(), source: .systemAudio)

        await logger.beginDraft(responseID: "r-a", triggerKind: .automatic, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [frameA])
        await logger.beginDraft(responseID: "r-b", triggerKind: .automatic, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [frameB])
        try await Task.sleep(for: .milliseconds(30))

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
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model")

        await logger.beginDraft(responseID: "r1", triggerKind: .automatic, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [])
        try await Task.sleep(for: .milliseconds(30))

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.questionTranscriptionStatus == .failed)
        #expect(saved?.questionText == nil)
    }

    @Test func transcriptionTimeoutSavesStatusFailed() async throws {
        let transcribing = FakeLocalTranscribing()
        await transcribing.setDelay(.milliseconds(200))
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model", whisperTimeout: .milliseconds(20))

        await logger.beginDraft(responseID: "r1", triggerKind: .automatic, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [])
        try await Task.sleep(for: .milliseconds(60))

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.questionTranscriptionStatus == .failed)
    }

    @Test func recordCancelledMarksStatusCancelled() async throws {
        let transcribing = FakeLocalTranscribing()
        await transcribing.setDelay(.milliseconds(200))
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model")

        await logger.beginDraft(responseID: "r1", triggerKind: .automatic, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [])
        await logger.recordCancelled(responseID: "r1")
        try await Task.sleep(for: .milliseconds(20))

        #expect(await repository.latest(responseID: "r1")?.status == .cancelled)
    }

    @Test func discardBeforeValidAnswerNeverPersistsAnything() async throws {
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model")

        await logger.discardBeforeValidAnswer(responseID: "never-started")
        await logger.recordCompleted(responseID: "never-started", finalText: "should not persist", responseTotalMs: nil)
        try await Task.sleep(for: .milliseconds(20))

        #expect(await repository.savedPairs.isEmpty)
        #expect(await transcribing.transcribeCallCount == 0)
    }

    @Test func twoConcurrentDraftsDoNotMix() async throws {
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model")

        await logger.beginDraft(responseID: "r1", triggerKind: .automatic, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [])
        await logger.beginDraft(responseID: "r2", triggerKind: .manual, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [])
        await logger.recordCompleted(responseID: "r1", finalText: "Ответ один", responseTotalMs: 100)
        await logger.recordCompleted(responseID: "r2", finalText: "Ответ два", responseTotalMs: 200)
        try await Task.sleep(for: .milliseconds(30))

        let pair1 = await repository.latest(responseID: "r1")
        let pair2 = await repository.latest(responseID: "r2")
        #expect(pair1?.answerText == "Ответ один")
        #expect(pair1?.triggerKind == .automatic)
        #expect(pair2?.answerText == "Ответ два")
        #expect(pair2?.triggerKind == .manual)
    }

    @Test func qaLoggerWritesAreOrdered() async throws {
        let transcribing = FakeLocalTranscribing()
        await transcribing.setResult([TranscribedSegment(text: "Поздний вопрос", startMs: 0, endMs: 100, source: .remote)])
        await transcribing.setDelay(.milliseconds(20))
        let repository = DelayedFirstWriteQuestionAnswerRepository(firstWriteDelay: .milliseconds(120))
        let logger = QuestionAnswerLogger(localTranscribing: transcribing, repository: repository, answerModelID: "test-model")

        await logger.beginDraft(responseID: "r1", triggerKind: .automatic, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [])
        await logger.recordCompleted(responseID: "r1", finalText: "Готово", responseTotalMs: 10)
        try await Task.sleep(for: .milliseconds(60))
        await logger.flush()

        let stored = await repository.stored.values.first
        #expect(await repository.writeOrder == [.answerStreaming, .completed, .completed])
        #expect(stored?.status == .completed)
        #expect(stored?.answerText == "Готово")
        #expect(stored?.questionText == "Поздний вопрос")
    }

    @Test func qaModelIDsAreAnswerAndTranscriptionModels() async throws {
        let transcribing = FakeLocalTranscribing()
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(
            localTranscribing: transcribing,
            repository: repository,
            answerModelID: "gpt-realtime-2.1",
            questionTranscriptionModelID: { "openai_whisper-small" }
        )

        await logger.beginDraft(responseID: "r1", triggerKind: .manual, sourceAppBundleID: nil, contextWindowStartedAt: Date(), contextSnapshot: [])
        await logger.flush()

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.answerModelID == "gpt-realtime-2.1")
        #expect(saved?.questionTranscriptionModelID == "openai_whisper-small")
    }
}

actor DelayedFirstWriteQuestionAnswerRepository: QuestionAnswerRepository {
    private let firstWriteDelay: Duration
    private var callCount = 0
    private(set) var stored: [UUID: QuestionAnswerPair] = [:]
    private(set) var writeOrder: [AnswerRecordStatus] = []

    init(firstWriteDelay: Duration) {
        self.firstWriteDelay = firstWriteDelay
    }

    func save(_ pair: QuestionAnswerPair) async throws {
        callCount += 1
        if callCount == 1 {
            try await Task.sleep(for: firstWriteDelay)
        }
        stored[pair.id] = pair
        writeOrder.append(pair.status)
    }

    func delete(id: UUID) async throws {
        stored[id] = nil
    }

    func deleteAll() async throws {
        stored = [:]
    }

    func history(limit: Int) async throws -> [QuestionAnswerPair] {
        Array(stored.values.prefix(limit))
    }

    func search(query: String) async throws -> [QuestionAnswerPair] {
        []
    }
}
