import Domain
import Foundation

public final class SQLiteQuestionAnswerRepository: QuestionAnswerRepository, Sendable {
    private let connection: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        connection = database
    }

    public convenience init(path: String) {
        self.init(database: SQLiteDatabase(path: path))
    }

    public func save(_ pair: QuestionAnswerPair) async throws {
        try await connection.ensureReady()
        let now = ISO8601DateFormatter().string(from: Date())
        try await connection.run(
            """
            INSERT INTO qa_entries (
                id, asked_at, source_bundle_id, question_text, question_status,
                context_started_at, context_duration_ms, trigger_kind, answer_text, answer_status,
                model_id, response_id, speech_end_to_first_delta_ms, first_delta_to_first_paint_ms,
                response_total_ms, usage_tokens, estimated_cost_usd, created_at, updated_at,
                question_transcription_model_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                question_text = excluded.question_text,
                question_status = excluded.question_status,
                answer_text = excluded.answer_text,
                answer_status = excluded.answer_status,
                speech_end_to_first_delta_ms = excluded.speech_end_to_first_delta_ms,
                first_delta_to_first_paint_ms = excluded.first_delta_to_first_paint_ms,
                response_total_ms = excluded.response_total_ms,
                usage_tokens = excluded.usage_tokens,
                estimated_cost_usd = excluded.estimated_cost_usd,
                updated_at = excluded.updated_at,
                question_transcription_model_id = excluded.question_transcription_model_id
            """,
            [
                .text(pair.id.uuidString),
                .text(ISO8601DateFormatter().string(from: pair.askedAt)),
                pair.sourceAppBundleID.map(SQLiteValue.text) ?? .null,
                pair.questionText.map(SQLiteValue.text) ?? .null,
                .text(pair.questionTranscriptionStatus.rawValueString),
                .text(ISO8601DateFormatter().string(from: pair.contextWindowStartedAt)),
                .int(pair.contextWindowDurationMs),
                .text(pair.triggerKind.rawValueString),
                .text(pair.answerText),
                .text(pair.status.rawValueString),
                .text(pair.answerModelID),
                .text(pair.responseID),
                pair.speechEndToFirstDeltaMs.map(SQLiteValue.int) ?? .null,
                pair.firstDeltaToFirstPaintMs.map(SQLiteValue.int) ?? .null,
                pair.responseTotalMs.map(SQLiteValue.int) ?? .null,
                pair.usageTokens.map(SQLiteValue.int) ?? .null,
                pair.estimatedCostUSD.map(SQLiteValue.double) ?? .null,
                .text(now),
                .text(now),
                pair.questionTranscriptionModelID.map(SQLiteValue.text) ?? .null,
            ]
        )
    }

    public func delete(id: UUID) async throws {
        try await connection.ensureReady()
        try await connection.run("DELETE FROM qa_entries WHERE id = ?", [.text(id.uuidString)])
    }

    public func deleteAll() async throws {
        try await connection.ensureReady()
        try await connection.run("DELETE FROM qa_entries")
    }

    public func history(limit: Int) async throws -> [QuestionAnswerPair] {
        try await connection.ensureReady()
        return try await connection.query(
            "SELECT \(Self.columns) FROM qa_entries ORDER BY asked_at DESC LIMIT ?",
            [.int(limit)],
            map: Self.rowMapper
        )
    }

    public func search(query: String) async throws -> [QuestionAnswerPair] {
        try await connection.ensureReady()
        let sanitized = query.replacingOccurrences(of: "\"", with: "")
        return try await connection.query(
            """
            SELECT \(Self.columns) FROM qa_entries
            WHERE rowid IN (SELECT rowid FROM qa_entries_fts WHERE qa_entries_fts MATCH ?)
            ORDER BY asked_at DESC
            """,
            [.text("\"\(sanitized)\"")],
            map: Self.rowMapper
        )
    }

    private static let columns = """
    id, asked_at, source_bundle_id, question_text, question_status, context_started_at, context_duration_ms,
    trigger_kind, answer_text, answer_status, model_id, response_id, speech_end_to_first_delta_ms,
    first_delta_to_first_paint_ms, response_total_ms, usage_tokens, estimated_cost_usd, question_transcription_model_id
    """

    private static func rowMapper(_ row: SQLiteRow) -> QuestionAnswerPair {
        return QuestionAnswerPair(
            id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
            askedAt: row.string(1).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date(),
            sourceAppBundleID: row.string(2),
            questionText: row.string(3),
            contextWindowStartedAt: row.string(5).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date(),
            contextWindowDurationMs: row.int(6) ?? 0,
            triggerKind: AnswerTriggerKind(rawValueString: row.string(7) ?? "") ?? .automatic,
            questionTranscriptionStatus: QuestionTranscriptionStatus(rawValueString: row.string(4) ?? "") ?? .pending,
            answerText: row.string(8) ?? "",
            answerModelID: row.string(10) ?? "",
            questionTranscriptionModelID: row.string(17),
            responseID: row.string(11) ?? "",
            speechEndToFirstDeltaMs: row.int(12),
            firstDeltaToFirstPaintMs: row.int(13),
            responseTotalMs: row.int(14),
            usageTokens: row.int(15),
            estimatedCostUSD: row.double(16),
            status: AnswerRecordStatus(rawValueString: row.string(9) ?? "") ?? .completed
        )
    }
}

extension AnswerTriggerKind {
    var rawValueString: String {
        switch self {
        case .automatic: "automatic"
        case .manual: "manual"
        }
    }

    init?(rawValueString: String) {
        switch rawValueString {
        case "automatic": self = .automatic
        case "manual": self = .manual
        default: return nil
        }
    }
}

extension QuestionTranscriptionStatus {
    var rawValueString: String {
        switch self {
        case .pending: "pending"
        case .completed: "completed"
        case .failed: "failed"
        }
    }

    init?(rawValueString: String) {
        switch rawValueString {
        case "pending": self = .pending
        case "completed": self = .completed
        case "failed": self = .failed
        default: return nil
        }
    }
}

extension AnswerRecordStatus {
    var rawValueString: String {
        switch self {
        case .answerStreaming: "answerStreaming"
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }

    init?(rawValueString: String) {
        switch rawValueString {
        case "answerStreaming": self = .answerStreaming
        case "completed": self = .completed
        case "cancelled": self = .cancelled
        case "failed": self = .failed
        default: return nil
        }
    }
}
