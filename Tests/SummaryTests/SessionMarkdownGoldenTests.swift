import Domain
import Foundation
import Testing
import Persistence
@testable import Summary

enum SessionMarkdownFixture {
    static let utc = TimeZone(identifier: "UTC")!
    static let start = Date(timeIntervalSince1970: 1_762_700_400)
    static let sessionID = SessionID(rawValue: UUID(uuidString: "8F0C6B2A-3D4E-4F50-9A1B-2C3D4E5F6A7B")!)
    static let firstAnswer = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let secondAnswer = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!

    static func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    static func pair(_ id: UUID, question: String?, answer: String, at seconds: TimeInterval, status: AnswerRecordStatus = .completed) -> QuestionAnswerPair {
        QuestionAnswerPair(
            id: id,
            askedAt: at(seconds),
            sourceAppBundleID: nil,
            questionText: question,
            contextWindowStartedAt: start,
            contextWindowDurationMs: 0,
            triggerKind: .automatic,
            answerText: answer,
            answerModelID: "gpt-realtime-test",
            responseID: "resp_\(Int(seconds))",
            status: status,
            sessionID: sessionID
        )
    }

    static func detail(title: String?) -> SessionDetail {
        let session = AssistantSession(
            id: sessionID,
            kind: .assistant,
            title: title,
            titleSource: .heuristic,
            startedAt: start,
            endedAt: at(3_920),
            status: .completed,
            lastActivityAt: at(3_920)
        )
        return SessionDetail(
            session: session,
            utterances: [
                SessionUtterance(id: "u1", speaker: .them, origin: .realtimeInput, text: "Чем Kafka отличается\nот RabbitMQ?", capturedAt: at(65), language: "ru"),
                SessionUtterance(id: "u2", speaker: .me, origin: .meChannel, text: "Kafka хранит лог, RabbitMQ — очередь.", capturedAt: at(80), language: "ru"),
                SessionUtterance(id: "u3", speaker: .them, origin: .realtimeInput, text: "How would you shard it?", capturedAt: at(3_725), language: "en", translationText: "Как бы вы это шардировали?", translationLanguage: "ru"),
                SessionUtterance(id: "u4", speaker: .them, origin: .realtimeInput, text: "Без времени", capturedAt: nil),
            ],
            questionAnswers: [
                pair(secondAnswer, question: "How would you shard it?", answer: "By customer id.", at: 3_726, status: .cancelled),
                pair(firstAnswer, question: "Чем Kafka отличается от RabbitMQ?", answer: "1. Kafka — распределённый лог.\n2. RabbitMQ — брокер очередей.", at: 66),
            ],
            bookmarks: [
                SessionBookmark(id: "bm_2", sessionID: sessionID, kind: .moment, markedAt: at(200), note: "вернуться к\nSLA"),
                SessionBookmark(id: "bm_1", sessionID: sessionID, kind: .star, questionAnswerID: firstAnswer, markedAt: at(90)),
            ],
            expansions: [
                SessionExpansion(id: "ex_1", questionAnswerID: firstAnswer, requestedAt: at(100), modelID: "claude-sonnet-5-5", status: "completed", text: "# Подробнее\n\nПартиции и consumer groups."),
            ],
            screenContexts: [
                SessionScreenContext(id: "scr_1", capturedAt: at(300), application: "Xcode", windowTitle: "Solver.swift", text: "func solve() {\n    let fence = \"```\"\n}"),
            ]
        )
    }

    static let summary = MeetingSummary(
        meetingID: sessionID,
        modelID: "gpt-5-mini",
        contentJSON: "{}",
        renderedMarkdown: "# Обсуждение очередей\n\n## Краткое резюме\nСравнили Kafka и RabbitMQ.",
        generatedAt: at(1_600)
    )
}

@Suite struct SessionMarkdownGoldenTests {
    private static func golden(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func check(_ rendered: String, against name: String) throws {
        if ProcessInfo.processInfo.environment["UA057_UPDATE_GOLDEN"] == "1" {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent(name)
            try rendered.write(to: url, atomically: true, encoding: .utf8)
        }
        #expect(rendered == (try golden(name)))
    }

    @Test func sessionMarkdownGoldenRussian() throws {
        let rendered = SessionMarkdownRenderer.render(
            SessionMarkdownFixture.detail(title: "09.11 · Чем Kafka отличается от RabbitMQ?"),
            summary: SessionMarkdownFixture.summary,
            labels: .russian,
            timeZone: SessionMarkdownFixture.utc
        )
        try Self.check(rendered, against: "session-ru.md")
    }

    @Test func sessionMarkdownGoldenEnglish() throws {
        let rendered = SessionMarkdownRenderer.render(
            SessionMarkdownFixture.detail(title: nil),
            summary: nil,
            labels: .english,
            timeZone: SessionMarkdownFixture.utc
        )
        try Self.check(rendered, against: "session-en.md")
    }

    @Test func sectionOrderIsFixed() {
        let rendered = SessionMarkdownRenderer.render(SessionMarkdownFixture.detail(title: "T"), summary: SessionMarkdownFixture.summary, timeZone: SessionMarkdownFixture.utc)
        let headings = rendered.components(separatedBy: "\n").filter { $0.hasPrefix("# ") || $0.hasPrefix("## ") }
        #expect(headings == ["# T", "## Саммари", "## Отмеченное", "## Вопросы и ответы", "## Транскрипт", "## Тексты экрана"])
    }

    @Test func emptySessionHasOnlyHeader() {
        let session = AssistantSession(id: SessionMarkdownFixture.sessionID, kind: .assistant, startedAt: SessionMarkdownFixture.start, status: .recording, lastActivityAt: SessionMarkdownFixture.start)
        let detail = SessionDetail(session: session, utterances: [], questionAnswers: [], bookmarks: [], expansions: [], screenContexts: [])
        #expect(SessionMarkdownRenderer.render(detail, timeZone: SessionMarkdownFixture.utc) == "# Сессия\n\n- Начало: 2025-11-09 15:00\n- Вопросов: 0 · Отметок: 0\n")
    }

    @Test func exporterNamesFileByStartTime() {
        #expect(SessionMarkdownExporter.filename(startedAt: SessionMarkdownFixture.start, timeZone: SessionMarkdownFixture.utc) == "UserAgent057-2025-11-09-1500.md")
    }
}

@Suite struct SessionMarkdownExporterTests {
    @Test func exporterRendersStoredSessionWithSummary() async throws {
        let database = SQLiteDatabase(path: ":memory:")
        let sessions = SQLiteSessionRepository(database: database)
        let summaries = SQLiteSummaryRepository(database: database)
        let session = try await sessions.create(kind: .assistant, mode: .answers, at: SessionMarkdownFixture.start)
        try await sessions.appendUtterance(SessionUtterance(id: "u1", speaker: .me, origin: .meChannel, text: "Привет", capturedAt: SessionMarkdownFixture.at(12)), sessionID: session.id)
        try await sessions.finish(sessionID: session.id, at: SessionMarkdownFixture.at(600))
        try await sessions.setTitle(sessionID: session.id, title: "Звонок 15:00", source: .heuristic)
        try await summaries.save(MeetingSummary(meetingID: session.id, modelID: "m", contentJSON: "{}", renderedMarkdown: "# Итог\n\nКоротко.", generatedAt: SessionMarkdownFixture.at(700)))

        let exporter = SessionMarkdownExporter(repository: sessions, summaries: summaries, timeZone: SessionMarkdownFixture.utc)
        let document = try #require(try await exporter.exportDocument(sessionID: session.id))
        #expect(document.filename == "UserAgent057-2025-11-09-1500.md")
        #expect(document.markdown.hasPrefix("# Звонок 15:00\n\n- Начало: 2025-11-09 15:00\n- Длительность: 10 мин\n"))
        #expect(document.markdown.contains("## Саммари\n\n### Итог\n\nКоротко."))
        #expect(document.markdown.contains("**[+00:12] Я:** Привет"))
        #expect(try await exporter.exportDocument(sessionID: SessionID()) == nil)
    }
}
