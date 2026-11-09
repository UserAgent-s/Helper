import Domain
import Foundation
import Testing
@testable import Persistence

@Suite struct SessionSearchTests {
    private let base = Date(timeIntervalSince1970: 1_793_000_000)

    private func stamp(_ seconds: Int) -> String {
        ISO8601DateFormatter().string(from: base.addingTimeInterval(TimeInterval(seconds)))
    }

    private struct Fixture {
        let database: SQLiteDatabase
        let sessions: SQLiteSessionRepository
        let search: SQLiteSessionSearchRepository
    }

    private func makeFixture() -> Fixture {
        let database = SQLiteDatabase(path: ":memory:")
        return Fixture(database: database, sessions: SQLiteSessionRepository(database: database), search: SQLiteSessionSearchRepository(database: database))
    }

    private func utterance(_ fixture: Fixture, _ session: SessionID, id: String, text: String, translation: String? = nil, at seconds: Int) async throws {
        try await fixture.database.run(
            "INSERT INTO utterances (id, meeting_id, source, started_ms, ended_ms, text, created_at, speaker, origin, captured_at, translation_text, translation_lang) VALUES (?, ?, 'remote', 0, 1, ?, ?, 'them', 'realtime_input', ?, ?, ?)",
            [.text(id), .text(session.rawValue.uuidString), .text(text), .text(stamp(seconds)), .text(stamp(seconds)), translation.map(SQLiteValue.text) ?? .null, translation == nil ? .null : .text("ru")]
        )
    }

    private func answer(_ fixture: Fixture, _ session: SessionID?, question: String, answer: String = "ответ", at seconds: Int) async throws {
        try await fixture.database.run(
            "INSERT INTO qa_entries (id, asked_at, question_status, trigger_kind, answer_text, answer_status, model_id, created_at, updated_at, question_text, session_id) VALUES (?, ?, 'completed', 'manual', ?, 'completed', 'gpt-realtime-2.1', ?, ?, ?, ?)",
            [.text(UUID().uuidString), .text(stamp(seconds)), .text(answer), .text(stamp(seconds)), .text(stamp(seconds)), .text(question), session.map { .text($0.rawValue.uuidString) } ?? .null]
        )
    }

    private func screen(_ fixture: Fixture, _ session: SessionID, id: String, text: String, at seconds: Int) async throws {
        try await fixture.database.run(
            "INSERT INTO screen_contexts (id, session_id, captured_at, application, window_title, text, created_at) VALUES (?, ?, ?, 'Xcode', 'Order.swift', ?, 'x')",
            [.text(id), .text(session.rawValue.uuidString), .text(stamp(seconds)), .text(text)]
        )
    }

    private func newSession(_ fixture: Fixture, at seconds: Int) async throws -> SessionID {
        try await fixture.sessions.create(kind: .assistant, mode: .answers, at: base.addingTimeInterval(TimeInterval(seconds))).id
    }

    private func itemIDs(_ results: [SessionSearchResult]) -> Set<String> {
        Set(results.flatMap { $0.hits.map(\.itemID) })
    }

    @Test func builderQuotesPrefixesAndExpandsAliases() {
        #expect(FTSQueryBuilder.tokens("  Kafka-консьюмеры, ЁЖИК  kafka ") == ["kafka", "консьюмеры", "ежик"])
        let query = FTSQueryBuilder.build("kafka консьюм", aliases: ["kafka": ["Кафка"]])
        #expect(query == FTSQuery(words: "(\"kafka\"* OR \"кафка\"*) AND \"консьюм\"*", trigrams: "(\"kafka\" OR \"кафка\") AND \"консьюм\""))
        #expect(FTSQueryBuilder.build("go kafka")?.trigrams == nil)
        #expect(FTSQueryBuilder.build("  \"*() ^:  ") == nil)
        #expect(FTSQueryBuilder.tokens((1...20).map { "t\($0)" }.joined(separator: " ")).count == FTSQueryBuilder.maxTokens)
    }

    @Test func prefixMatchesCyrillic() async throws {
        let fixture = makeFixture()
        let session = try await newSession(fixture, at: 0)
        try await utterance(fixture, session, id: "u1", text: "Мы используем Kafka-консьюмеры для очереди", at: 1)
        try await utterance(fixture, session, id: "u2", text: "Один консьюмер на партицию", at: 2)
        try await utterance(fixture, session, id: "u3", text: "Про брокеры поговорим позже", at: 3)

        let both = try await fixture.search.search(query: "kafka консьюм", limit: 10)
        #expect(itemIDs(both) == ["u1"])
        let prefix = try await fixture.search.search(query: "консьюм", limit: 10)
        #expect(itemIDs(prefix) == ["u1", "u2"])
        let alias = try await fixture.search.search(query: "кафка", limit: 10)
        #expect(itemIDs(alias) == ["u1"])
    }

    @Test func caseInsensitiveCyrillic() async throws {
        let fixture = makeFixture()
        let session = try await newSession(fixture, at: 0)
        try await utterance(fixture, session, id: "u1", text: "ШАРДИРОВАНИЕ по ключу клиента", at: 1)
        try await utterance(fixture, session, id: "u2", text: "Ёмкость кластера", at: 2)

        #expect(itemIDs(try await fixture.search.search(query: "шардирование", limit: 10)) == ["u1"])
        #expect(itemIDs(try await fixture.search.search(query: "ШаРдИр", limit: 10)) == ["u1"])
        #expect(itemIDs(try await fixture.search.search(query: "емкость", limit: 10)) == ["u2"])
        #expect(itemIDs(try await fixture.search.search(query: "ЁМКОСТЬ", limit: 10)) == ["u2"])
    }

    @Test func nonAdjacentTermsMatch() async throws {
        let fixture = makeFixture()
        let session = try await newSession(fixture, at: 0)
        try await utterance(fixture, session, id: "u1", text: "Kafka хранит офсеты, а консьюмер их коммитит", at: 1)
        try await utterance(fixture, session, id: "u2", text: "Kafka без потребителей", at: 2)

        #expect(itemIDs(try await fixture.search.search(query: "консьюмер kafka", limit: 10)) == ["u1"])
        #expect(itemIDs(try await fixture.search.search(query: "офсет коммит", limit: 10)) == ["u1"])
    }

    @Test func quotesAndOperatorsSanitized() async throws {
        let fixture = makeFixture()
        let session = try await newSession(fixture, at: 0)
        try await utterance(fixture, session, id: "u1", text: "Kafka-консьюмеры читают партиции", at: 1)
        try await answer(fixture, session, question: "Что такое Kafka?", at: 2)
        let meetings = SQLiteMeetingRepository(database: fixture.database)
        let answers = SQLiteQuestionAnswerRepository(database: fixture.database)

        for hostile in ["\"Kafka\" (консьюм*", "kafka\"\"\" консьюм:*", "(kafka) + консьюм)", "kafka* ^консьюм -партиции", "{kafka}: 'консьюм'"] {
            #expect(itemIDs(try await fixture.search.search(query: hostile, limit: 10)).contains("u1"))
        }
        #expect(try await fixture.search.search(query: "kafka OR redis", limit: 10).isEmpty)
        #expect(try await fixture.search.search(query: "NEAR(kafka redis, 2)", limit: 10).isEmpty)
        for broken in ["\"", "AND OR NOT", "(((", "*", ":", "  ", "NEAR(", "text:"] {
            _ = try await fixture.search.search(query: broken, limit: 10)
            _ = try await meetings.search(query: broken)
            _ = try await answers.search(query: broken)
        }
        #expect(try await meetings.search(query: "\"kafka консьюм").map(\.id.rawValue) == [session.rawValue])
        #expect(try await answers.search(query: "что KAFKA?").count == 1)
        #expect(try await answers.search(query: "кафка").count == 1)
    }

    @Test func resultsGroupedBySessionWithSnippet() async throws {
        let fixture = makeFixture()
        let first = try await newSession(fixture, at: 0)
        let second = try await newSession(fixture, at: 100)
        try await fixture.sessions.setTitle(sessionID: first, title: "Собеседование", source: .user)
        try await utterance(fixture, first, id: "u1", text: "Начнём с того, что Kafka гарантирует порядок только внутри партиции", at: 1)
        try await answer(fixture, first, question: "Как Kafka хранит офсеты?", at: 2)
        try await utterance(fixture, second, id: "u2", text: "Про Kafka поговорим в следующий раз", at: 101)
        try await answer(fixture, nil, question: "Kafka без сессии", at: 3)

        let results = try await fixture.search.search(query: "kafka", limit: 10)
        #expect(Set(results.map(\.sessionID)) == [first, second])
        let grouped = try #require(results.first { $0.sessionID == first })
        #expect(grouped.title == "Собеседование")
        #expect(grouped.kind == .assistant)
        #expect(Set(grouped.hits.map(\.source)) == [.utterance, .questionAnswer])
        #expect(grouped.hits.allSatisfy { $0.sessionID == first && $0.snippet.contains("«Kafka»") })
        #expect(results.flatMap(\.hits).count == 3)
        #expect(try await fixture.search.search(query: "kafka", limit: 1).count == 1)

        for index in 0..<6 {
            try await utterance(fixture, second, id: "extra\(index)", text: "Kafka номер \(index)", at: 110 + index)
        }
        let capped = try await fixture.search.search(query: "kafka", limit: 10)
        #expect(capped.allSatisfy { $0.hits.count <= SQLiteSessionSearchRepository.hitsPerSession })
    }

    @Test func searchesTranslationAndScreenText() async throws {
        let fixture = makeFixture()
        let session = try await newSession(fixture, at: 0)
        try await utterance(fixture, session, id: "u1", text: "How do you handle backpressure?", translation: "Как вы справляетесь с обратным давлением?", at: 1)
        try await screen(fixture, session, id: "s1", text: "func shardKey(for customer: Customer) -> Int", at: 2)
        try await fixture.database.run(
            "INSERT INTO deep_expansions (id, session_id, qa_entry_id, requested_at, model_id, status, text, created_at, updated_at) VALUES ('d1', ?, NULL, ?, 'claude-sonnet-5-5', 'completed', 'Идемпотентность продюсера', 'x', 'x')",
            [.text(session.rawValue.uuidString), .text(stamp(3))]
        )
        try await fixture.sessions.addBookmark(SessionBookmark(sessionID: session, kind: .moment, questionAnswerID: nil, markedAt: base.addingTimeInterval(4), note: "вернуться к ретраям"))

        let translation = try await fixture.search.search(query: "давлением", limit: 10)
        #expect(translation.first?.hits.map(\.source) == [.utterance])
        #expect(translation.first?.hits.first?.snippet.contains("«давлением»") == true)
        let screenHit = try await fixture.search.search(query: "shardkey", limit: 10)
        #expect(screenHit.first?.hits.map(\.source) == [.screenText])
        #expect(screenHit.first?.hits.first?.itemID == "s1")
        let infix = try await fixture.search.search(query: "ardKe", limit: 10)
        #expect(infix.first?.hits.map(\.itemID) == ["s1"])
        #expect(try await fixture.search.search(query: "идемпотент", limit: 10).first?.hits.map(\.source) == [.expansion])
        #expect(try await fixture.search.search(query: "ретра", limit: 10).first?.hits.map(\.source) == [.bookmark])
    }
}
