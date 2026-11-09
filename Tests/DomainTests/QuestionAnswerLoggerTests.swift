import Foundation
import Testing
@testable import Domain

@Suite struct QuestionAnswerLoggerTests {

    private func final(_ itemID: String, _ text: String, language: String? = nil) -> TranscriptEvent {
        TranscriptEvent(speaker: .them, itemID: itemID, text: text, language: language, isFinal: true)
    }

    private func begin(_ logger: QuestionAnswerLogger, _ responseID: String, items: [String], trigger: AnswerTriggerKind = .automatic) async {
        await logger.beginDraft(responseID: responseID, triggerKind: trigger, sourceAppBundleID: nil, contextWindowStartedAt: Date(), questionItemIDs: items)
    }

    @Test func nothingPersistedBeforeBeginDraft() async {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")
        await logger.recordTranscript(final("u1", "Вопрос"))
        await logger.flush()
        #expect(await repository.savedPairs.isEmpty)
    }

    @Test func beginDraftPersistsAnswerStreamingWhileTranscriptPending() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")

        await logger.beginDraft(responseID: "r1", triggerKind: .automatic, sourceAppBundleID: "com.example.meet", contextWindowStartedAt: Date(), questionItemIDs: ["u1"])
        await logger.flush()

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.status == .answerStreaming)
        #expect(saved?.questionText == nil)
        #expect(saved?.questionTranscriptionStatus == .pending)
        #expect(saved?.sourceAppBundleID == "com.example.meet")
    }

    @Test func committedThenDeltaThenCompletedAttachesFinalText() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")

        await begin(logger, "r1", items: ["u1"])
        await logger.recordTranscript(TranscriptEvent(speaker: .them, itemID: "u1", text: "Расскажите", isFinal: false))
        await logger.flush()
        #expect(await repository.latest(responseID: "r1")?.questionText == nil)

        await logger.recordTranscript(final("u1", "Расскажите про Kafka", language: "ru"))
        await logger.flush()
        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.questionText == "Расскажите про Kafka")
        #expect(saved?.questionTranscriptionStatus == .completed)
    }

    @Test func completedBeforeDraftIsUsedImmediately() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")

        await logger.recordTranscript(final("u1", "Первая часть"))
        await logger.recordTranscript(final("u2", "вторая часть?"))
        await begin(logger, "r1", items: ["u1", "u2"])
        await logger.flush()

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.questionText == "Первая часть вторая часть?")
        #expect(saved?.questionTranscriptionStatus == .completed)
    }

    @Test func failedItemDoesNotBlockOtherParts() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")

        await begin(logger, "r1", items: ["u1", "u2"])
        await logger.recordTranscriptFailed(itemID: "u1")
        await logger.recordTranscript(final("u2", "Как масштабировать?"))
        await logger.flush()

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.questionText == "Как масштабировать?")
        #expect(saved?.questionTranscriptionStatus == .completed)
    }

    @Test func allItemsFailedMarksQuestionNotRecognized() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")

        await begin(logger, "r1", items: ["u1"])
        await logger.recordTranscriptFailed(itemID: "u1")
        await logger.flush()

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.questionTranscriptionStatus == .failed)
        #expect(saved?.questionText == nil)
    }

    @Test func noQuestionItemsMarksQuestionNotRecognizedAtOnce() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")

        await begin(logger, "r1", items: [], trigger: .manual)
        await logger.flush()

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.questionTranscriptionStatus == .failed)
        #expect(saved?.triggerKind == .manual)
    }

    @Test func transcriptTimeoutKeepsPartialTextOrFails() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model", transcriptTimeout: .milliseconds(20))

        await begin(logger, "partial", items: ["u1", "u2"])
        await logger.recordTranscript(final("u1", "Только начало"))
        await begin(logger, "none", items: ["u9"])
        try await Task.sleep(for: .milliseconds(80))
        await logger.flush()

        #expect(await repository.latest(responseID: "partial")?.questionText == "Только начало")
        #expect(await repository.latest(responseID: "partial")?.questionTranscriptionStatus == .completed)
        #expect(await repository.latest(responseID: "none")?.questionTranscriptionStatus == .failed)
    }

    @Test func answerSavedEvenWhileQuestionStillPending() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")

        await begin(logger, "r1", items: ["u1"])
        await logger.recordCompleted(responseID: "r1", finalText: "Готовый ответ", responseTotalMs: 850)
        await logger.flush()

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.answerText == "Готовый ответ")
        #expect(saved?.status == .completed)
        #expect(saved?.questionText == nil)

        await logger.recordTranscript(final("u1", "Поздний вопрос"))
        await logger.flush()
        let late = await repository.latest(responseID: "r1")
        #expect(late?.questionText == "Поздний вопрос")
        #expect(late?.answerText == "Готовый ответ")
        #expect(late?.id == saved?.id)
        #expect(await logger.pendingDraftCount == 0)
    }

    @Test func lateTranscriptsUpdateTheirOwnDrafts() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")

        await begin(logger, "r-a", items: ["a"])
        await begin(logger, "r-b", items: ["b"])
        await logger.recordTranscript(final("b", "Вопрос B"))
        await logger.recordTranscript(final("a", "Вопрос A"))
        await logger.flush()

        let pairA = await repository.latest(responseID: "r-a")
        let pairB = await repository.latest(responseID: "r-b")
        #expect(pairA?.questionText == "Вопрос A")
        #expect(pairB?.questionText == "Вопрос B")
        #expect(pairA?.id != pairB?.id)
    }

    @Test func recordCancelledMarksStatusCancelled() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")

        await begin(logger, "r1", items: ["u1"])
        await logger.recordCancelled(responseID: "r1")
        await logger.flush()

        #expect(await repository.latest(responseID: "r1")?.status == .cancelled)
    }

    @Test func discardBeforeValidAnswerNeverPersistsAnything() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")

        await logger.discardBeforeValidAnswer(responseID: "never-started")
        await logger.recordCompleted(responseID: "never-started", finalText: "should not persist", responseTotalMs: nil)
        await logger.flush()

        #expect(await repository.savedPairs.isEmpty)
    }

    @Test func twoConcurrentDraftsDoNotMix() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")

        await begin(logger, "r1", items: [])
        await begin(logger, "r2", items: [], trigger: .manual)
        await logger.recordCompleted(responseID: "r1", finalText: "Ответ один", responseTotalMs: 100)
        await logger.recordCompleted(responseID: "r2", finalText: "Ответ два", responseTotalMs: 200)
        await logger.flush()

        let pair1 = await repository.latest(responseID: "r1")
        let pair2 = await repository.latest(responseID: "r2")
        #expect(pair1?.answerText == "Ответ один")
        #expect(pair1?.triggerKind == .automatic)
        #expect(pair2?.answerText == "Ответ два")
        #expect(pair2?.triggerKind == .manual)
    }

    @Test func qaLoggerWritesAreOrdered() async throws {
        let repository = DelayedFirstWriteQuestionAnswerRepository(firstWriteDelay: .milliseconds(120))
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model")

        await begin(logger, "r1", items: ["u1"])
        await logger.recordCompleted(responseID: "r1", finalText: "Готово", responseTotalMs: 10)
        await logger.recordTranscript(final("u1", "Поздний вопрос"))
        await logger.flush()

        let stored = await repository.stored.values.first
        #expect(await repository.writeOrder == [.answerStreaming, .completed, .completed])
        #expect(stored?.status == .completed)
        #expect(stored?.answerText == "Готово")
        #expect(stored?.questionText == "Поздний вопрос")
    }

    @Test func qaModelIDsAreAnswerAndTranscriptionModels() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(
            repository: repository,
            answerModelID: "gpt-realtime-2.1",
            questionTranscriptionModelID: { "gpt-transcribe" }
        )

        await begin(logger, "r1", items: [], trigger: .manual)
        await logger.flush()

        let saved = await repository.latest(responseID: "r1")
        #expect(saved?.answerModelID == "gpt-realtime-2.1")
        #expect(saved?.questionTranscriptionModelID == "gpt-transcribe")
    }

    @Test func transcriptRetentionIsBounded() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model", transcriptTimeout: .milliseconds(20), transcriptRetention: 2)

        await logger.recordTranscript(final("old", "Старое"))
        await logger.recordTranscript(final("x", "x"))
        await logger.recordTranscript(final("y", "y"))
        await begin(logger, "r1", items: ["old"])
        try await Task.sleep(for: .milliseconds(60))
        await logger.flush()

        #expect(await repository.latest(responseID: "r1")?.questionTranscriptionStatus == .failed)
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
