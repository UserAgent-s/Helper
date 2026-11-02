import AppKit
import Domain
import Foundation
import Observation
import PDFKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class KnowledgeBaseViewModel {
    nonisolated static let maxImportBytes = 2_000_000

    private let repository: any KnowledgeNoteRepository
    private let settingsStore: AppSettingsStore
    private let sessionStatus: SessionStatusViewModel

    private(set) var notes: [KnowledgeNote] = []
    private(set) var importMessages: [String] = []
    private(set) var context = KnowledgeContext.empty
    var editingNote: KnowledgeNote?

    init(repository: any KnowledgeNoteRepository, settingsStore: AppSettingsStore, sessionStatus: SessionStatusViewModel) {
        self.repository = repository
        self.settingsStore = settingsStore
        self.sessionStatus = sessionStatus
    }

    var totalEnabledCharacters: Int {
        notes.filter(\.isEnabled).reduce(0) { $0 + $1.content.count }
    }

    var approximateTokens: Int {
        Int(Double(context.text.count) / 3.0)
    }

    var budgetCharacters: Int {
        KnowledgeContextBuilder.defaultBudgetCharacters
    }

    func load() async {
        notes = (try? await repository.all()) ?? []
        recomputeContext()
    }

    func addEmptyNote() {
        editingNote = KnowledgeNote(title: loc("Новая заметка"), content: CandidateProfile.caseTemplate)
    }

    func save(_ note: KnowledgeNote) async {
        var updated = note
        updated.updatedAt = Date()
        updated.title = updated.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? loc("Без названия") : updated.title
        try? await repository.save(updated)
        editingNote = nil
        await load()
    }

    func setEnabled(_ enabled: Bool, for note: KnowledgeNote) async {
        var updated = note
        updated.isEnabled = enabled
        try? await repository.save(updated)
        await load()
    }

    func delete(_ note: KnowledgeNote) async {
        try? await repository.delete(id: note.id)
        await load()
    }

    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text, .pdf, UTType(filenameExtension: "md") ?? .plainText]
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor [weak self] in
                await self?.importFiles(urls)
            }
        }
    }

    func importFiles(_ urls: [URL]) async {
        var messages: [String] = []
        for url in urls {
            switch Self.extractText(from: url) {
            case .success(let text):
                let note = KnowledgeNote(title: url.deletingPathExtension().lastPathComponent, content: text, sourceFileName: url.lastPathComponent)
                try? await repository.save(note)
                messages.append(loc("Импортировано:") + " \(url.lastPathComponent) (\(text.count) " + loc("символов") + ")")
            case .failure(let reason):
                messages.append(loc("Не удалось импортировать") + " \(url.lastPathComponent): \(reason.message)")
            }
        }
        importMessages = messages
        await load()
    }

    struct ImportFailure: Error {
        let message: String
    }

    nonisolated static func extractText(from url: URL) -> Result<String, ImportFailure> {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxImportBytes else {
            return .failure(ImportFailure(message: "file is larger than 2 MB"))
        }
        let text: String?
        if url.pathExtension.lowercased() == "pdf" {
            text = PDFDocument(url: url)?.string
        } else {
            text = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
        }
        guard let text else {
            return .failure(ImportFailure(message: "unsupported or unreadable file"))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ImportFailure(message: "no text found"))
        }
        return .success(trimmed)
    }

    private func recomputeContext() {
        context = KnowledgeContextBuilder.build(notes)
        settingsStore.liveContext.update(knowledge: context)
        sessionStatus.refreshPendingState()
    }
}
