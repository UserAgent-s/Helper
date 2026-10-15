import Foundation
import Testing
import Domain
@testable import Persistence

@Suite struct SQLiteQuestionAnswerRepositoryTests {

    private func pair(id: UUID = UUID(), responseID: String = "r1", triggerKind: AnswerTriggerKind = .automatic, status: AnswerRecordStatus = .answerStreaming, questionText: String? = nil, answerText: String = "") -> QuestionAnswerPair {
        QuestionAnswerPair(
            id: id,
            askedAt: Date(),
            sourceAppBundleID: "com.example.meet",
            questionText: questionText,
            contextWindowStartedAt: Date(),
            contextWindowDurationMs: 1200,
            triggerKind: triggerKind,
            answerText: answerText,
            modelID: "gpt-realtime-2.1",
            responseID: responseID,
            status: status
        )
    }

    @Test func savingTwiceWithSameIDUpsertsRatherThanDuplicates() async throws {
        let repository = SQLiteQuestionAnswerRepository(path: ":memory:")
        let id = UUID()
        try await repository.save(pair(id: id, status: .answerStreaming, answerText: "Готовлю ответ"))
        try await repository.save(pair(id: id, status: .completed, questionText: "Как устроен GC?", answerText: "Готовлю ответ"))

        let history = try await repository.history(limit: 10)
        #expect(history.count == 1)
        #expect(history.first?.status == .completed)
        #expect(history.first?.questionText == "Как устроен GC?")
    }

    @Test func triggerKindPersistsThroughRoundTrip() async throws {
        let repository = SQLiteQuestionAnswerRepository(path: ":memory:")
        try await repository.save(pair(triggerKind: .manual, answerText: "Ответ по кнопке"))

        let history = try await repository.history(limit: 10)
        #expect(history.first?.triggerKind == .manual)
    }

    @Test func contextWindowDurationSurvivesRoundTrip() async throws {
        let repository = SQLiteQuestionAnswerRepository(path: ":memory:")
        try await repository.save(pair(answerText: "ok"))

        let saved = try await repository.history(limit: 10).first
        #expect(saved?.contextWindowDurationMs == 1200)
    }

    @Test func deleteRemovesOnlyTheTargetedEntry() async throws {
        let repository = SQLiteQuestionAnswerRepository(path: ":memory:")
        let keepID = UUID()
        let removeID = UUID()
        try await repository.save(pair(id: keepID, responseID: "keep", answerText: "keep"))
        try await repository.save(pair(id: removeID, responseID: "remove", answerText: "remove"))

        try await repository.delete(id: removeID)

        let remaining = try await repository.history(limit: 10)
        #expect(remaining.map(\.id) == [keepID])
    }

    @Test func deleteAllClearsEveryEntry() async throws {
        let repository = SQLiteQuestionAnswerRepository(path: ":memory:")
        try await repository.save(pair(responseID: "a"))
        try await repository.save(pair(responseID: "b"))

        try await repository.deleteAll()

        let remaining = try await repository.history(limit: 10)
        #expect(remaining.isEmpty)
    }

    @Test func searchMatchesQuestionOrAnswerTextButNotUnrelatedEntries() async throws {
        let repository = SQLiteQuestionAnswerRepository(path: ":memory:")
        try await repository.save(pair(responseID: "a", questionText: "Как работает Kubernetes?", answerText: "Kubernetes оркестрирует контейнеры"))
        try await repository.save(pair(responseID: "b", questionText: "Какая сегодня погода?", answerText: "Не знаю"))

        let results = try await repository.search(query: "Kubernetes")
        #expect(results.map(\.responseID) == ["a"])
    }

    @Test func concurrentDraftUpdatesForDifferentIDsDoNotCorruptEachOther() async throws {
        let repository = SQLiteQuestionAnswerRepository(path: ":memory:")
        let idA = UUID()
        let idB = UUID()

        async let saveA: Void = repository.save(pair(id: idA, responseID: "a", answerText: "Ответ A"))
        async let saveB: Void = repository.save(pair(id: idB, responseID: "b", answerText: "Ответ B"))
        _ = try await (saveA, saveB)

        let history = try await repository.history(limit: 10)
        let a = history.first { $0.id == idA }
        let b = history.first { $0.id == idB }
        #expect(a?.answerText == "Ответ A")
        #expect(b?.answerText == "Ответ B")
    }
}
