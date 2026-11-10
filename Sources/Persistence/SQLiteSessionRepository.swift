import Domain
import Foundation

public final class SQLiteSessionRepository: SessionRepository, DeepExpansionStoring, Sendable {
    private let connection: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        connection = database
    }

    public func create(kind: SessionKind, mode: SessionSpanMode, at date: Date) async throws -> AssistantSession {
        let id = SessionID()
        let span = SessionSpan(sessionID: id, mode: mode, startedAt: date)
        let stamp = Self.format(date)
        try await connection.transaction([
            (
                """
                INSERT INTO meetings (id, title, source_bundle_id, started_at, ended_at, status, created_at, updated_at, kind, last_activity_at)
                VALUES (?, NULL, NULL, ?, NULL, ?, ?, ?, ?, ?)
                """,
                [.text(Self.key(id)), .text(stamp), .text(MeetingStatus.recording.rawValueString), .text(stamp), .text(stamp), .text(kind.rawValue), .text(stamp)]
            ),
            Self.insertSpan(span),
        ])
        return AssistantSession(id: id, kind: kind, startedAt: Self.normalized(date), status: .recording, lastActivityAt: Self.normalized(date), spans: [Self.normalizedSpan(span)])
    }

    public func resume(sessionID: SessionID, mode: SessionSpanMode, at date: Date) async throws -> SessionSpan {
        guard let existing = try await session(id: sessionID) else {
            throw SQLitePersistenceError.notFound("session \(sessionID.rawValue)")
        }
        if let open = existing.openSpan, open.mode == mode, existing.status == .recording {
            return open
        }
        let span = SessionSpan(sessionID: sessionID, mode: mode, startedAt: date)
        let stamp = Self.format(date)
        try await connection.transaction([
            (
                "UPDATE session_spans SET ended_at = ?, end_reason = ? WHERE session_id = ? AND ended_at IS NULL",
                [.text(stamp), .text(SessionSpanEndReason.modeChanged.rawValue), .text(Self.key(sessionID))]
            ),
            Self.insertSpan(span),
            (
                "UPDATE meetings SET status = ?, ended_at = NULL, last_activity_at = ?, updated_at = ? WHERE id = ?",
                [.text(MeetingStatus.recording.rawValueString), .text(stamp), .text(stamp), .text(Self.key(sessionID))]
            ),
        ])
        return Self.normalizedSpan(span)
    }

    public func closeSpan(id: String, at date: Date, reason: SessionSpanEndReason) async throws {
        let stamp = Self.format(date)
        try await connection.transaction([
            (
                "UPDATE meetings SET last_activity_at = ?, updated_at = ? WHERE id = (SELECT session_id FROM session_spans WHERE id = ? AND ended_at IS NULL)",
                [.text(stamp), .text(stamp), .text(id)]
            ),
            (
                "UPDATE session_spans SET ended_at = ?, end_reason = ? WHERE id = ? AND ended_at IS NULL",
                [.text(stamp), .text(reason.rawValue), .text(id)]
            ),
        ])
    }

    public func finish(sessionID: SessionID, at date: Date) async throws {
        let stamp = Self.format(date)
        try await connection.transaction([
            (
                "UPDATE session_spans SET ended_at = ?, end_reason = ? WHERE session_id = ? AND ended_at IS NULL",
                [.text(stamp), .text(SessionSpanEndReason.stopped.rawValue), .text(Self.key(sessionID))]
            ),
            (
                "UPDATE meetings SET status = ?, ended_at = ?, last_activity_at = ?, updated_at = ? WHERE id = ?",
                [.text(MeetingStatus.completed.rawValueString), .text(stamp), .text(stamp), .text(stamp), .text(Self.key(sessionID))]
            ),
        ])
    }

    public func session(id: SessionID) async throws -> AssistantSession? {
        try await connection.ensureReady()
        let rows = try await connection.query(
            "SELECT id, kind, title, title_source, started_at, ended_at, status, pinned, last_activity_at FROM meetings WHERE id = ?",
            [.text(Self.key(id))],
            map: Self.sessionMapper
        )
        guard var session = rows.first else { return nil }
        session.spans = try await connection.query(
            "SELECT id, session_id, mode, started_at, ended_at, end_reason FROM session_spans WHERE session_id = ? ORDER BY started_at, rowid",
            [.text(Self.key(id))],
            map: Self.spanMapper
        )
        return session
    }

    public func headers(limit: Int, after cursor: SessionCursor?) async throws -> SessionPage {
        try await connection.ensureReady()
        var filter = ""
        var params: [SQLiteValue] = []
        if let cursor {
            filter = "WHERE m.started_at < ? OR (m.started_at = ? AND m.id < ?)"
            params = [.text(Self.format(cursor.startedAt)), .text(Self.format(cursor.startedAt)), .text(Self.key(cursor.id))]
        }
        let rows = try await connection.query(
            """
            SELECT m.id, m.kind, m.title, m.started_at, m.ended_at, m.status, m.pinned, m.last_activity_at,
                (SELECT COUNT(*) FROM qa_entries q WHERE q.session_id = m.id),
                (SELECT COUNT(*) FROM bookmarks b WHERE b.session_id = m.id AND b.kind = 'star')
            FROM meetings m \(filter)
            ORDER BY m.started_at DESC, m.id DESC
            LIMIT ?
            """,
            params + [.int(limit + 1)],
            map: Self.headerMapper
        )
        let page = Array(rows.prefix(limit))
        let next = rows.count > limit ? page.last.map { SessionCursor(startedAt: $0.startedAt, id: $0.id) } : nil
        return SessionPage(headers: page, nextCursor: next)
    }

    public func detail(sessionID: SessionID) async throws -> SessionDetail? {
        guard let session = try await session(id: sessionID) else { return nil }
        let key: [SQLiteValue] = [.text(Self.key(sessionID))]
        let utterances = try await connection.query(
            """
            SELECT id, speaker, origin, text, captured_at, language, translation_text, translation_lang
            FROM utterances WHERE meeting_id = ? ORDER BY COALESCE(captured_at, ''), started_ms, rowid
            """,
            key,
            map: Self.utteranceMapper
        )
        let answers = try await connection.query(
            "SELECT \(SQLiteQuestionAnswerRepository.columns) FROM qa_entries WHERE session_id = ? ORDER BY asked_at, rowid",
            key,
            map: SQLiteQuestionAnswerRepository.rowMapper
        )
        let bookmarks = try await bookmarks(sessionID: sessionID)
        let expansions = try await connection.query(
            "SELECT id, qa_entry_id, requested_at, model_id, status, text FROM deep_expansions WHERE session_id = ? ORDER BY requested_at, rowid",
            key,
            map: Self.expansionMapper
        )
        let screens = try await connection.query(
            "SELECT id, captured_at, application, window_title, text FROM screen_contexts WHERE session_id = ? ORDER BY captured_at, rowid",
            key,
            map: Self.screenMapper
        )
        return SessionDetail(session: session, utterances: utterances, questionAnswers: answers, bookmarks: bookmarks, expansions: expansions, screenContexts: screens)
    }

    public func addBookmark(_ bookmark: SessionBookmark) async throws {
        let stamp = Self.format(bookmark.markedAt)
        try await connection.transaction([
            (
                "INSERT INTO bookmarks (id, session_id, kind, qa_entry_id, marked_at, note, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [
                    .text(bookmark.id),
                    .text(Self.key(bookmark.sessionID)),
                    .text(bookmark.kind.rawValue),
                    bookmark.questionAnswerID.map { .text($0.uuidString) } ?? .null,
                    .text(stamp),
                    bookmark.note.map(SQLiteValue.text) ?? .null,
                    .text(Self.format(Date())),
                ]
            ),
            ("UPDATE meetings SET last_activity_at = MAX(COALESCE(last_activity_at, ''), ?) WHERE id = ?", [.text(stamp), .text(Self.key(bookmark.sessionID))]),
        ])
    }

    public func bookmarks(sessionID: SessionID) async throws -> [SessionBookmark] {
        try await connection.ensureReady()
        return try await connection.query(
            "SELECT id, session_id, kind, qa_entry_id, marked_at, note FROM bookmarks WHERE session_id = ? ORDER BY marked_at, rowid",
            [.text(Self.key(sessionID))],
            map: Self.bookmarkMapper
        )
    }

    public func latestCompletedAnswerID(sessionID: SessionID) async throws -> UUID? {
        try await connection.ensureReady()
        return try await connection.query(
            "SELECT id FROM qa_entries WHERE session_id = ? AND answer_status = ? ORDER BY asked_at DESC, rowid DESC LIMIT 1",
            [.text(Self.key(sessionID)), .text(AnswerRecordStatus.completed.rawValueString)],
            map: { $0.string(0).flatMap(UUID.init(uuidString:)) }
        ).first ?? nil
    }

    public func removeBookmark(id: String) async throws {
        try await connection.transaction([("DELETE FROM bookmarks WHERE id = ?", [.text(id)])])
    }

    public func setTitle(sessionID: SessionID, title: String, source: SessionTitleSource) async throws {
        try await connection.transaction([
            ("UPDATE meetings SET title = ?, title_source = ?, updated_at = ? WHERE id = ?", [.text(title), .text(source.rawValue), .text(Self.format(Date())), .text(Self.key(sessionID))]),
        ])
    }

    public func setPinned(sessionID: SessionID, pinned: Bool) async throws {
        try await connection.transaction([
            ("UPDATE meetings SET pinned = ?, updated_at = ? WHERE id = ?", [.int(pinned ? 1 : 0), .text(Self.format(Date())), .text(Self.key(sessionID))]),
        ])
    }

    public func setKnowledgeDigest(sessionID: SessionID, digest: String) async throws {
        try await connection.transaction([
            ("UPDATE meetings SET knowledge_digest = ?, updated_at = ? WHERE id = ?", [.text(digest), .text(Self.format(Date())), .text(Self.key(sessionID))]),
        ])
    }

    public func knowledgeDigest(sessionID: SessionID) async throws -> String? {
        try await connection.ensureReady()
        return try await connection.query(
            "SELECT knowledge_digest FROM meetings WHERE id = ?",
            [.text(Self.key(sessionID))],
            map: { $0.string(0) }
        ).first ?? nil
    }

    public func purge(olderThan date: Date, excluding active: SessionID?) async throws -> [SessionID] {
        try await connection.ensureReady()
        let ids = try await connection.query(
            """
            SELECT id FROM meetings
            WHERE COALESCE(last_activity_at, started_at) < ? AND status != ? AND pinned = 0 AND id != ?
            """,
            [.text(Self.format(date)), .text(MeetingStatus.recording.rawValueString), .text(active.map(Self.key) ?? "")],
            map: { $0.string(0) }
        ).compactMap { $0 }
        try await connection.transaction(ids.map { ("DELETE FROM meetings WHERE id = ?", [.text($0)]) })
        return ids.compactMap(UUID.init(uuidString:)).map(SessionID.init(rawValue:))
    }

    public func appendUtterance(_ utterance: SessionUtterance, sessionID: SessionID) async throws {
        let stamp = Self.format(utterance.capturedAt ?? Date())
        let key = Self.key(sessionID)
        try await connection.transaction([
            (
                """
                INSERT INTO utterances (id, meeting_id, source, started_ms, ended_ms, text, language, confidence, created_at, speaker, origin, captured_at, translation_text, translation_lang)
                SELECT ?, id, ?, offset_ms, offset_ms, ?, ?, NULL, ?, ?, ?, ?, ?, ?
                FROM (SELECT id, MAX(0, CAST(ROUND((julianday(?) - julianday(started_at)) * 86400000) AS INTEGER)) AS offset_ms FROM meetings WHERE id = ?)
                """,
                [
                    .text(utterance.id),
                    .text(utterance.speaker == .me ? "local" : "remote"),
                    .text(utterance.text),
                    utterance.language.map(SQLiteValue.text) ?? .null,
                    .text(Self.format(Date())),
                    .text(utterance.speaker.rawValue),
                    .text(utterance.origin.rawValue),
                    .text(stamp),
                    utterance.translationText.map(SQLiteValue.text) ?? .null,
                    utterance.translationLanguage.map(SQLiteValue.text) ?? .null,
                    .text(stamp),
                    .text(key),
                ]
            ),
            ("UPDATE meetings SET last_activity_at = ? WHERE id = ?", [.text(stamp), .text(key)]),
        ])
    }

    public func deleteIfEmpty(sessionID: SessionID) async throws -> Bool {
        try await connection.ensureReady()
        return try await connection.deleteSessionIfEmpty(Self.key(sessionID))
    }

    public func saveExpansion(_ record: DeepExpansionRecord) async throws {
        let stamp = Self.format(Date())
        func opt(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
        func opt(_ value: Int?) -> SQLiteValue { value.map(SQLiteValue.int) ?? .null }
        func opt(_ value: Double?) -> SQLiteValue { value.map(SQLiteValue.double) ?? .null }
        let usageTotal: Int? = {
            let parts = [record.inputTokens, record.outputTokens, record.cacheReadTokens, record.cacheWriteTokens].compactMap { $0 }
            return parts.isEmpty ? nil : parts.reduce(0, +)
        }()
        try await connection.transaction([
            (
                """
                INSERT INTO deep_expansions (id, session_id, qa_entry_id, requested_at, model_id, status, text, usage_tokens, estimated_cost_usd, created_at, updated_at,
                    parent_id, source_kind, point_id, source_text, format, language, ttft_ms, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, stop_reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    qa_entry_id = excluded.qa_entry_id, model_id = excluded.model_id, status = excluded.status, text = excluded.text,
                    usage_tokens = excluded.usage_tokens, estimated_cost_usd = excluded.estimated_cost_usd, updated_at = excluded.updated_at,
                    ttft_ms = excluded.ttft_ms, input_tokens = excluded.input_tokens, output_tokens = excluded.output_tokens,
                    cache_read_tokens = excluded.cache_read_tokens, cache_write_tokens = excluded.cache_write_tokens, stop_reason = excluded.stop_reason
                """,
                [
                    .text(record.id), .text(Self.key(record.sessionID)), opt(record.questionAnswerID?.uuidString), .text(Self.format(record.requestedAt)),
                    .text(record.modelID), .text(record.status), .text(record.text), opt(usageTotal), opt(record.estimatedCostUSD), .text(stamp), .text(stamp),
                    opt(record.parentID), .text(record.sourceKind), opt(record.pointID), .text(record.sourceText), .text(record.format), .text(record.language),
                    opt(record.ttftMs), opt(record.inputTokens), opt(record.outputTokens), opt(record.cacheReadTokens), opt(record.cacheWriteTokens), opt(record.stopReason),
                ]
            ),
            ("UPDATE meetings SET last_activity_at = MAX(COALESCE(last_activity_at, ''), ?) WHERE id = ?", [.text(stamp), .text(Self.key(record.sessionID))]),
        ])
    }

    public func expansionRecord(id: String) async throws -> DeepExpansionRecord? {
        try await connection.ensureReady()
        return try await connection.query(
            """
            SELECT id, session_id, qa_entry_id, parent_id, requested_at, model_id, status, text, source_kind, point_id, source_text, format, language,
                ttft_ms, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, estimated_cost_usd, stop_reason
            FROM deep_expansions WHERE id = ?
            """,
            [.text(id)],
            map: { row in
                DeepExpansionRecord(
                    id: row.string(0) ?? "",
                    sessionID: Self.sessionID(row.string(1)),
                    questionAnswerID: row.string(2).flatMap(UUID.init(uuidString:)),
                    parentID: row.string(3),
                    requestedAt: Self.parse(row.string(4)) ?? Date(timeIntervalSince1970: 0),
                    modelID: row.string(5) ?? "",
                    status: row.string(6) ?? "",
                    text: row.string(7) ?? "",
                    sourceKind: row.string(8) ?? "",
                    pointID: row.string(9),
                    sourceText: row.string(10) ?? "",
                    format: row.string(11) ?? "",
                    language: row.string(12) ?? "",
                    ttftMs: row.int(13),
                    inputTokens: row.int(14),
                    outputTokens: row.int(15),
                    cacheReadTokens: row.int(16),
                    cacheWriteTokens: row.int(17),
                    estimatedCostUSD: row.double(18),
                    stopReason: row.string(19)
                )
            }
        ).first
    }

    public func questionAnswerID(responseID: String) async throws -> UUID? {
        try await connection.ensureReady()
        return try await connection.query(
            "SELECT id FROM qa_entries WHERE response_id = ? ORDER BY asked_at DESC LIMIT 1",
            [.text(responseID)],
            map: { $0.string(0).flatMap(UUID.init(uuidString:)) }
        ).first ?? nil
    }

    private static func key(_ id: SessionID) -> String {
        id.rawValue.uuidString
    }

    private static func format(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func parse(_ string: String?) -> Date? {
        string.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    private static func normalized(_ date: Date) -> Date {
        parse(format(date)) ?? date
    }

    private static func normalizedSpan(_ span: SessionSpan) -> SessionSpan {
        SessionSpan(id: span.id, sessionID: span.sessionID, mode: span.mode, startedAt: normalized(span.startedAt), endedAt: span.endedAt.map(normalized), endReason: span.endReason)
    }

    private static func sessionID(_ string: String?) -> SessionID {
        SessionID(rawValue: string.flatMap(UUID.init(uuidString:)) ?? UUID())
    }

    private static func insertSpan(_ span: SessionSpan) -> (String, [SQLiteValue]) {
        (
            "INSERT INTO session_spans (id, session_id, mode, started_at, ended_at, end_reason) VALUES (?, ?, ?, ?, NULL, NULL)",
            [.text(span.id), .text(key(span.sessionID)), .text(span.mode.rawValue), .text(format(span.startedAt))]
        )
    }

    private static func sessionMapper(_ row: SQLiteRow) -> AssistantSession {
        let startedAt = parse(row.string(4)) ?? Date()
        return AssistantSession(
            id: sessionID(row.string(0)),
            kind: SessionKind(rawValue: row.string(1) ?? "") ?? .recording,
            title: row.string(2),
            titleSource: row.string(3).flatMap(SessionTitleSource.init(rawValue:)),
            startedAt: startedAt,
            endedAt: parse(row.string(5)),
            status: MeetingStatus(rawValueString: row.string(6) ?? "") ?? .failed,
            pinned: (row.int(7) ?? 0) != 0,
            lastActivityAt: parse(row.string(8)) ?? startedAt
        )
    }

    private static func spanMapper(_ row: SQLiteRow) -> SessionSpan {
        SessionSpan(
            id: row.string(0) ?? "",
            sessionID: sessionID(row.string(1)),
            mode: SessionSpanMode(rawValue: row.string(2) ?? "") ?? .recording,
            startedAt: parse(row.string(3)) ?? Date(),
            endedAt: parse(row.string(4)),
            endReason: row.string(5).flatMap(SessionSpanEndReason.init(rawValue:))
        )
    }

    private static func headerMapper(_ row: SQLiteRow) -> SessionHeader {
        let startedAt = parse(row.string(3)) ?? Date()
        return SessionHeader(
            id: sessionID(row.string(0)),
            kind: SessionKind(rawValue: row.string(1) ?? "") ?? .recording,
            title: row.string(2),
            startedAt: startedAt,
            endedAt: parse(row.string(4)),
            status: MeetingStatus(rawValueString: row.string(5) ?? "") ?? .failed,
            pinned: (row.int(6) ?? 0) != 0,
            lastActivityAt: parse(row.string(7)) ?? startedAt,
            questionAnswerCount: row.int(8) ?? 0,
            starCount: row.int(9) ?? 0
        )
    }

    private static func utteranceMapper(_ row: SQLiteRow) -> SessionUtterance {
        SessionUtterance(
            id: row.string(0) ?? "",
            speaker: Speaker(rawValue: row.string(1) ?? "") ?? .them,
            origin: UtteranceOrigin(rawValue: row.string(2) ?? "") ?? .whisperLocal,
            text: row.string(3) ?? "",
            capturedAt: parse(row.string(4)),
            language: row.string(5),
            translationText: row.string(6),
            translationLanguage: row.string(7)
        )
    }

    private static func bookmarkMapper(_ row: SQLiteRow) -> SessionBookmark {
        SessionBookmark(
            id: row.string(0) ?? "",
            sessionID: sessionID(row.string(1)),
            kind: BookmarkKind(rawValue: row.string(2) ?? "") ?? .moment,
            questionAnswerID: row.string(3).flatMap(UUID.init(uuidString:)),
            markedAt: parse(row.string(4)) ?? Date(),
            note: row.string(5)
        )
    }

    private static func expansionMapper(_ row: SQLiteRow) -> SessionExpansion {
        SessionExpansion(
            id: row.string(0) ?? "",
            questionAnswerID: row.string(1).flatMap(UUID.init(uuidString:)),
            requestedAt: parse(row.string(2)) ?? Date(),
            modelID: row.string(3) ?? "",
            status: row.string(4) ?? "",
            text: row.string(5) ?? ""
        )
    }

    private static func screenMapper(_ row: SQLiteRow) -> SessionScreenContext {
        SessionScreenContext(
            id: row.string(0) ?? "",
            capturedAt: parse(row.string(1)) ?? Date(),
            application: row.string(2),
            windowTitle: row.string(3),
            text: row.string(4) ?? ""
        )
    }
}

extension SQLiteDatabase {
    func deleteSessionIfEmpty(_ key: String) throws -> Bool {
        var deleted = 0
        try withTransaction {
            deleted = try run(
                """
                DELETE FROM meetings WHERE id = ?
                AND NOT EXISTS (SELECT 1 FROM utterances WHERE meeting_id = meetings.id)
                AND NOT EXISTS (SELECT 1 FROM qa_entries WHERE session_id = meetings.id)
                AND NOT EXISTS (SELECT 1 FROM bookmarks WHERE session_id = meetings.id)
                AND NOT EXISTS (SELECT 1 FROM screen_contexts WHERE session_id = meetings.id)
                AND NOT EXISTS (SELECT 1 FROM deep_expansions WHERE session_id = meetings.id)
                AND NOT EXISTS (SELECT 1 FROM session_spans WHERE session_id = meetings.id AND mode = 'recording')
                AND pinned = 0
                """,
                [.text(key)]
            )
        }
        return deleted > 0
    }

    func transaction(_ statements: [(String, [SQLiteValue])]) throws {
        try ensureReady()
        guard !statements.isEmpty else { return }
        try withTransaction {
            for (sql, params) in statements {
                try run(sql, params)
            }
        }
    }
}
