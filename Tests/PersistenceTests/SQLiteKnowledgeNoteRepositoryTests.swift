import Foundation
import Testing
import Domain
@testable import Persistence

@Suite struct SQLiteKnowledgeNoteRepositoryTests {
    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("ma-knowledge-\(UUID().uuidString).sqlite3").path
    }

    @Test func savesUpdatesTogglesAndDeletesNotes() async throws {
        let repository = SQLiteKnowledgeNoteRepository(path: temporaryDatabasePath())
        var note = KnowledgeNote(title: "Resume", content: "PHP, Laravel, AWS SQS", sourceFileName: "resume.md")
        try await repository.save(note)
        note.isEnabled = false
        note.content = "PHP, Yii2"
        try await repository.save(note)
        let stored = try await repository.all()
        #expect(stored.count == 1)
        #expect(stored.first?.content == "PHP, Yii2")
        #expect(stored.first?.isEnabled == false)
        #expect(stored.first?.sourceFileName == "resume.md")
        try await repository.delete(id: note.id)
        #expect(try await repository.all().isEmpty)
    }

    @Test func coexistsWithExistingRepositoriesOnTheSameDatabase() async throws {
        let path = temporaryDatabasePath()
        async let qa: Void = SQLiteQuestionAnswerRepository(path: path).deleteAll()
        async let notes = SQLiteKnowledgeNoteRepository(path: path).all()
        async let meetings = SQLiteMeetingRepository(path: path).history(limit: 1, offset: 0)
        _ = try await (qa, notes, meetings)
        try await SQLiteKnowledgeNoteRepository(path: path).save(KnowledgeNote(title: "a", content: "b"))
        #expect(try await SQLiteKnowledgeNoteRepository(path: path).all().count == 1)
    }
}
