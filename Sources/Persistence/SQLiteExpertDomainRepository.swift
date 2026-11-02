import Domain
import Foundation

public final class SQLiteExpertDomainRepository: ExpertDomainRepository, Sendable {
    private let connection: SQLiteConnection

    public init(path: String) {
        connection = SQLiteConnection(path: path)
    }

    public func save(_ domain: ExpertDomain) async throws {
        try await connection.ensureReady()
        try await connection.run(
            """
            INSERT INTO expert_domains (id, name, role, guidance, is_active, sort_order, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                role = excluded.role,
                guidance = excluded.guidance,
                is_active = excluded.is_active,
                sort_order = excluded.sort_order,
                updated_at = excluded.updated_at
            """,
            [
                .text(domain.id.uuidString),
                .text(domain.name),
                .text(domain.role),
                .text(domain.guidance),
                .int(domain.isActive ? 1 : 0),
                .int(domain.sortOrder),
                .text(ISO8601DateFormatter().string(from: domain.updatedAt)),
            ]
        )
    }

    public func delete(id: UUID) async throws {
        try await connection.ensureReady()
        try await connection.runInTransaction([
            (sql: "UPDATE knowledge_notes SET domain_id = NULL WHERE domain_id = ?", params: [.text(id.uuidString)]),
            (sql: "DELETE FROM expert_domains WHERE id = ?", params: [.text(id.uuidString)]),
        ])
    }

    public func all() async throws -> [ExpertDomain] {
        try await connection.ensureReady()
        return try await connection.query(
            "SELECT id, name, role, guidance, is_active, sort_order, updated_at FROM expert_domains ORDER BY sort_order ASC, name ASC",
            map: { row in
                ExpertDomain(
                    id: row.string(0).flatMap(UUID.init(uuidString:)) ?? UUID(),
                    name: row.string(1) ?? "",
                    role: row.string(2) ?? "",
                    guidance: row.string(3) ?? "",
                    isActive: (row.int(4) ?? 1) != 0,
                    sortOrder: row.int(5) ?? 0,
                    updatedAt: row.string(6).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
                )
            }
        )
    }
}
