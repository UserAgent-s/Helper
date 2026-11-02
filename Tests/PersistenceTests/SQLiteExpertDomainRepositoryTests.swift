import Foundation
import Testing
import Domain
@testable import Persistence

@Suite struct SQLiteExpertDomainRepositoryTests {
    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("ma-domains-\(UUID().uuidString).sqlite3").path
    }

    @Test func savesUpdatesAndListsDomainsInSortOrder() async throws {
        let repository = SQLiteExpertDomainRepository(path: temporaryDatabasePath())
        try await repository.save(ExpertDomain(name: "Second", sortOrder: 2))
        var first = ExpertDomain(name: "First", role: "r", guidance: "g", isActive: false, sortOrder: 1)
        try await repository.save(first)
        first.name = "First renamed"
        first.isActive = true
        try await repository.save(first)
        let all = try await repository.all()
        #expect(all.map(\.name) == ["First renamed", "Second"])
        #expect(all.first?.isActive == true)
        #expect(all.first?.role == "r")
        #expect(all.first?.guidance == "g")
    }

    @Test func deletingDomainDetachesItsNotesInsteadOfDeletingThem() async throws {
        let path = temporaryDatabasePath()
        let domains = SQLiteExpertDomainRepository(path: path)
        let notes = SQLiteKnowledgeNoteRepository(path: path)
        let domain = ExpertDomain(name: "Kubernetes")
        try await domains.save(domain)
        try await notes.save(KnowledgeNote(title: "n", content: "c", domainID: domain.id, origin: .folder))
        try await domains.delete(id: domain.id)
        #expect(try await domains.all().isEmpty)
        let stored = try await notes.all()
        #expect(stored.count == 1)
        #expect(stored.first?.domainID == nil)
        #expect(stored.first?.origin == .folder)
    }

    @Test func notesPersistDomainAndOrigin() async throws {
        let notes = SQLiteKnowledgeNoteRepository(path: temporaryDatabasePath())
        let id = UUID()
        try await notes.save(KnowledgeNote(title: "n", content: "c", sourceFileName: "Area/n.md", domainID: id, origin: .folder))
        let stored = try await notes.all().first
        #expect(stored?.domainID == id)
        #expect(stored?.origin == .folder)
        #expect(stored?.sourceFileName == "Area/n.md")
    }

    @Test func migratingVersionTwoDatabaseKeepsOldNotesAsShared() async throws {
        let path = temporaryDatabasePath()
        let legacy = SQLiteConnection(path: path)
        try await legacy.ensureReady()
        try await legacy.run("DELETE FROM schema_migrations WHERE version = 3")
        try await legacy.run("DROP TABLE expert_domains")
        try await legacy.run("""
        CREATE TABLE knowledge_notes_v2 (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, content TEXT NOT NULL, is_enabled INTEGER NOT NULL, source_file_name TEXT, updated_at TEXT NOT NULL
        )
        """)
        try await legacy.run("DROP TABLE knowledge_notes")
        try await legacy.run("ALTER TABLE knowledge_notes_v2 RENAME TO knowledge_notes")
        try await legacy.run("INSERT INTO knowledge_notes (id, title, content, is_enabled, source_file_name, updated_at) VALUES (?, 'Old', 'old content', 1, NULL, ?)", [.text(UUID().uuidString), .text("2026-01-01T00:00:00Z")])

        let notes = SQLiteKnowledgeNoteRepository(path: path)
        let stored = try await notes.all()
        #expect(stored.count == 1)
        #expect(stored.first?.title == "Old")
        #expect(stored.first?.domainID == nil)
        #expect(stored.first?.origin == .manual)
        let domains = SQLiteExpertDomainRepository(path: path)
        #expect(try await domains.all().isEmpty)
    }
}
