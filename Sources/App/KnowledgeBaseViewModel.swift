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

    private let library: KnowledgeLibrary
    private let settingsStore: AppSettingsStore
    private let sessionStatus: SessionStatusViewModel
    let folderURL: URL

    private(set) var snapshot = KnowledgeLibrarySnapshot.empty
    private(set) var importMessages: [String] = []
    private(set) var isSyncing = false
    var editingNote: KnowledgeNote?
    var editingDomain: ExpertDomain?
    var importTargetDomainID: UUID?

    init(library: KnowledgeLibrary, folderURL: URL, settingsStore: AppSettingsStore, sessionStatus: SessionStatusViewModel) {
        self.library = library
        self.folderURL = folderURL
        self.settingsStore = settingsStore
        self.sessionStatus = sessionStatus
    }

    var notes: [KnowledgeNote] { snapshot.notes }
    var domains: [ExpertDomain] { snapshot.domains }
    var context: KnowledgeContext { snapshot.context }

    var approximateTokens: Int {
        Int(Double(context.text.count) / 3.0)
    }

    var budgetCharacters: Int {
        KnowledgeContextBuilder.defaultBudgetCharacters
    }

    var lastSyncSummary: String? {
        snapshot.lastSyncSummary
    }

    func load() async {
        isSyncing = true
        apply(await library.refresh())
        isSyncing = false
    }

    func reload() async {
        apply(await library.snapshot())
    }

    func syncFolder() async {
        guard !isSyncing else { return }
        isSyncing = true
        apply(await library.refresh())
        isSyncing = false
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folderURL)
    }

    func domainName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return domains.first { $0.id == id }?.trimmedName
    }

    func noteCount(for domain: ExpertDomain) -> Int {
        snapshot.noteCount(for: domain)
    }

    func addEmptyNote() {
        editingNote = KnowledgeNote(title: loc("Новая заметка"), content: CandidateProfile.caseTemplate, domainID: importTargetDomainID)
    }

    func save(_ note: KnowledgeNote) async {
        var updated = note
        updated.updatedAt = Date()
        updated.title = updated.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? loc("Без названия") : updated.title
        await library.saveNote(updated)
        editingNote = nil
        await reload()
    }

    func setEnabled(_ enabled: Bool, for note: KnowledgeNote) async {
        var updated = note
        updated.isEnabled = enabled
        await library.saveNote(updated)
        await reload()
    }

    func assign(_ note: KnowledgeNote, to domainID: UUID?) async {
        var updated = note
        updated.domainID = domainID
        updated.updatedAt = Date()
        await library.saveNote(updated)
        await reload()
    }

    func delete(_ note: KnowledgeNote) async {
        await library.deleteNote(id: note.id)
        await reload()
    }

    func addDomain() {
        let nextOrder = (domains.map(\.sortOrder).max() ?? -1) + 1
        editingDomain = ExpertDomain(name: "", role: "", guidance: "", isActive: true, sortOrder: nextOrder)
    }

    func save(_ domain: ExpertDomain) async {
        await library.saveDomain(domain)
        editingDomain = nil
        await reload()
    }

    func setActive(_ active: Bool, for domain: ExpertDomain) async {
        var updated = domain
        updated.isActive = active
        await library.saveDomain(updated)
        await reload()
    }

    func delete(_ domain: ExpertDomain) async {
        await library.deleteDomain(id: domain.id)
        if importTargetDomainID == domain.id { importTargetDomainID = nil }
        await reload()
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
                let note = KnowledgeNote(title: url.deletingPathExtension().lastPathComponent, content: text, sourceFileName: url.lastPathComponent, domainID: importTargetDomainID)
                await library.saveNote(note)
                messages.append(loc("Импортировано:") + " \(url.lastPathComponent) (\(text.count) " + loc("символов") + ")")
            case .failure(let reason):
                messages.append(loc("Не удалось импортировать") + " \(url.lastPathComponent): \(reason.message)")
            }
        }
        importMessages = messages
        await reload()
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

    private func apply(_ snapshot: KnowledgeLibrarySnapshot) {
        self.snapshot = snapshot
        settingsStore.liveContext.update(domains: snapshot.domains)
        settingsStore.liveContext.update(knowledge: snapshot.context)
        sessionStatus.refreshPendingState()
    }
}
