import Domain
import Foundation

public final class SQLiteSummaryRepository: SummaryRepository, Sendable {
    private let connection: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        connection = database
    }

    public convenience init(path: String) {
        self.init(database: SQLiteDatabase(path: path))
    }

    public func save(_ summary: MeetingSummary) async throws {
        try await connection.ensureReady()
        try await connection.run(
            """
            INSERT INTO summaries (id, meeting_id, model_id, schema_version, content_json, rendered_markdown, usage_tokens, estimated_cost_usd, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(summary.id.uuidString),
                .text(summary.meetingID.rawValue.uuidString),
                .text(summary.modelID),
                .int(summary.schemaVersion),
                .text(summary.contentJSON),
                .text(summary.renderedMarkdown),
                summary.usageTokens.map(SQLiteValue.int) ?? .null,
                summary.estimatedCostUSD.map(SQLiteValue.double) ?? .null,
                .text(ISO8601DateFormatter().string(from: summary.generatedAt)),
            ]
        )
    }

    public func fetch(meetingID: MeetingID) async throws -> MeetingSummary? {
        try await connection.ensureReady()
        let results = try await connection.query(
            """
            SELECT id, meeting_id, model_id, schema_version, content_json, rendered_markdown, usage_tokens, estimated_cost_usd, created_at
            FROM summaries WHERE meeting_id = ? ORDER BY created_at DESC LIMIT 1
            """,
            [.text(meetingID.rawValue.uuidString)],
            map: { row in
                MeetingSummary(
                    id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
                    meetingID: MeetingID(rawValue: UUID(uuidString: row.string(1) ?? "") ?? UUID()),
                    modelID: row.string(2) ?? "",
                    schemaVersion: row.int(3) ?? 1,
                    contentJSON: row.string(4) ?? "",
                    renderedMarkdown: row.string(5) ?? "",
                    usageTokens: row.int(6),
                    estimatedCostUSD: row.double(7),
                    generatedAt: row.string(8).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
                )
            }
        )
        return results.first
    }
}
