import Domain
import Foundation

public final class SQLiteKnowledgeNoteRepository: KnowledgeNoteRepository, Sendable {
    private let connection: SQLiteConnection

    public init(path: String) {
        connection = SQLiteConnection(path: path)
    }

    public func save(_ note: KnowledgeNote) async throws {
        try await connection.ensureReady()
        try await connection.run(
            """
            INSERT INTO knowledge_notes (id, title, content, is_enabled, source_file_name, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                content = excluded.content,
                is_enabled = excluded.is_enabled,
                source_file_name = excluded.source_file_name,
                updated_at = excluded.updated_at
            """,
            [
                .text(note.id.uuidString),
                .text(note.title),
                .text(note.content),
                .int(note.isEnabled ? 1 : 0),
                note.sourceFileName.map(SQLiteValue.text) ?? .null,
                .text(ISO8601DateFormatter().string(from: note.updatedAt)),
            ]
        )
    }

    public func delete(id: UUID) async throws {
        try await connection.ensureReady()
        try await connection.run("DELETE FROM knowledge_notes WHERE id = ?", [.text(id.uuidString)])
    }

    public func all() async throws -> [KnowledgeNote] {
        try await connection.ensureReady()
        return try await connection.query(
            "SELECT id, title, content, is_enabled, source_file_name, updated_at FROM knowledge_notes ORDER BY updated_at ASC",
            map: { row in
                KnowledgeNote(
                    id: row.string(0).flatMap(UUID.init(uuidString:)) ?? UUID(),
                    title: row.string(1) ?? "",
                    content: row.string(2) ?? "",
                    isEnabled: (row.int(3) ?? 1) != 0,
                    sourceFileName: row.string(4),
                    updatedAt: row.string(5).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
                )
            }
        )
    }
}
