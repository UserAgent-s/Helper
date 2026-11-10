import Domain
import Foundation
import Testing
@testable import Persistence

@Suite struct DeepExpansionStoreTests {
    private func record(_ session: SessionID, id: String = "exp-1", status: String = "streaming", text: String = "", parent: String? = nil) -> DeepExpansionRecord {
        DeepExpansionRecord(
            id: id, sessionID: session, questionAnswerID: nil, parentID: parent, requestedAt: Date(timeIntervalSince1970: 1_793_000_100),
            modelID: "claude-sonnet-5-5", status: status, text: text, sourceKind: parent == nil ? "point" : "follow_up", pointID: "r1.0",
            sourceText: "Платёжный шлюз", format: "short", language: "ru"
        )
    }

    @Test func migrationV5AddsColumnsAndUpsertKeepsOneRow() async throws {
        let database = SQLiteDatabase(path: ":memory:")
        let repository = SQLiteSessionRepository(database: database)
        #expect(try await database.appliedMigrationVersions().contains(5))
        let session = try await repository.create(kind: .assistant, mode: .answers, at: Date(timeIntervalSince1970: 1_793_000_000))
        try await repository.saveExpansion(record(session.id))
        var final = record(session.id, status: "completed", text: "Я строил шлюз идемпотентным")
        final.ttftMs = 640
        final.inputTokens = 40
        final.outputTokens = 120
        final.cacheReadTokens = 21_000
        final.cacheWriteTokens = 0
        final.estimatedCostUSD = 0.0057
        final.stopReason = "end_turn"
        try await repository.saveExpansion(final)
        try await repository.saveExpansion(record(session.id, id: "exp-2", status: "completed", text: "Ограничения: ретраи", parent: "exp-1"))

        let stored = try #require(try await repository.expansionRecord(id: "exp-1"))
        #expect(stored.status == "completed")
        #expect(stored.text == "Я строил шлюз идемпотентным")
        #expect(stored.ttftMs == 640)
        #expect(stored.cacheReadTokens == 21_000)
        #expect(stored.estimatedCostUSD == 0.0057)
        #expect(stored.format == "short")
        #expect(stored.sourceText == "Платёжный шлюз")
        #expect(try await repository.expansionRecord(id: "exp-2")?.parentID == "exp-1")
        let detail = try #require(try await repository.detail(sessionID: session.id))
        #expect(detail.expansions.map(\.id) == ["exp-1", "exp-2"])

        let hits = try await SQLiteSessionSearchRepository(database: database).search(query: "идемпотентным", limit: 10)
        #expect(hits.map(\.sessionID) == [session.id])
    }

    @Test func questionAnswerLookupByResponseID() async throws {
        let database = SQLiteDatabase(path: ":memory:")
        let repository = SQLiteSessionRepository(database: database)
        #expect(try await repository.questionAnswerID(responseID: "resp_x") == nil)
        let id = UUID()
        let stamp = ISO8601DateFormatter().string(from: Date())
        try await database.run(
            "INSERT INTO qa_entries (id, asked_at, question_status, trigger_kind, answer_text, answer_status, model_id, response_id, created_at, updated_at) VALUES (?, ?, 'completed', 'manual', 'a', 'completed', 'gpt-realtime-2.1', 'resp_x', ?, ?)",
            [.text(id.uuidString), .text(stamp), .text(stamp), .text(stamp)]
        )
        #expect(try await repository.questionAnswerID(responseID: "resp_x") == id)
    }

    @Test func instructionProfileIsRecordedPerSession() async throws {
        let database = SQLiteDatabase(path: ":memory:")
        let repository = SQLiteSessionRepository(database: database)
        let a = try await repository.create(kind: .assistant, mode: .answers, at: Date(timeIntervalSince1970: 1_793_000_000))
        let b = try await repository.create(kind: .assistant, mode: .answers, at: Date(timeIntervalSince1970: 1_793_000_100))
        #expect(try await repository.instructionProfile(sessionID: a.id) == nil)
        try await repository.setInstructionProfile(sessionID: a.id, profile: .bilingualAssist, digestSource: .cached)
        #expect(try await repository.instructionProfile(sessionID: a.id) == .bilingualAssist)
        #expect(try await repository.instructionProfile(sessionID: b.id) == nil)
    }

    @Test func screenContextIsSavedSearchableAndInDetail() async throws {
        let database = SQLiteDatabase(path: ":memory:")
        let repository = SQLiteSessionRepository(database: database)
        let session = try await repository.create(kind: .assistant, mode: .answers, at: Date(timeIntervalSince1970: 1_793_000_000))
        try await repository.saveScreenContext(SessionScreenContext(id: "scr_1", capturedAt: Date(timeIntervalSince1970: 1_793_000_050), application: "Chrome", windowTitle: "Task", text: "Реализуйте LRU-кеш с вытеснением"), sessionID: session.id)
        let detail = try #require(try await repository.detail(sessionID: session.id))
        #expect(detail.screenContexts.map(\.text) == ["Реализуйте LRU-кеш с вытеснением"])
        #expect(try await SQLiteSessionSearchRepository(database: database).search(query: "вытеснением", limit: 5).map(\.sessionID) == [session.id])
    }
}
