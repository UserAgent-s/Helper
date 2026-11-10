import AppKit
import Domain
import Foundation
import Observation
import ProfileKnowledge

@MainActor
@Observable
final class ProfileSettingsViewModel {
    enum Status: Equatable {
        case noFolder
        case ok
        case warning
        case error(String)
    }

    private let settingsStore: AppSettingsStore
    private let provider: MarkdownFolderProfileProvider
    private let limits: ProfileLimits

    private(set) var folderPath: String?
    private(set) var candidates: [ProfileCandidate] = []
    private(set) var selectedPaths: Set<String> = []
    private(set) var usesDefaultSelection = true
    private(set) var status: Status = .noFolder
    private(set) var documentCount = 0
    private(set) var totalBytes = 0
    private(set) var estimatedTokens = 0
    private(set) var fingerprint = ""
    private(set) var keywords: [String] = []

    init(settingsStore: AppSettingsStore, provider: MarkdownFolderProfileProvider, limits: ProfileLimits = .standard) {
        self.settingsStore = settingsStore
        self.provider = provider
        self.limits = limits
    }

    var selectedBytes: Int {
        candidates.filter { selectedPaths.contains($0.relativePath) }.reduce(0) { $0 + $1.byteCount }
    }

    func reload() async {
        let config = settingsStore.profileFolderConfiguration()
        folderPath = config.folder?.path
        if config.folder == nil, settingsStore.profileFolderBookmark != nil {
            folderPath = nil
            candidates = []
            status = .error(loc("Папка профиля недоступна: выберите её заново"))
            return
        }
        do {
            candidates = try await provider.candidates()
        } catch {
            candidates = []
        }
        usesDefaultSelection = config.selectedPaths == nil
        selectedPaths = Set(ProfileSelection.effectivePaths(stored: config.selectedPaths, candidates: candidates))
        do {
            let snapshot = try await provider.snapshot()
            documentCount = snapshot.documents.count
            totalBytes = snapshot.totalBytes
            estimatedTokens = snapshot.estimatedTokens
            fingerprint = snapshot.fingerprint
            keywords = await provider.transcriptionKeywords()
            switch snapshot.source {
            case .markdownFolder:
                status = snapshot.sizeStatus == .warning ? .warning : .ok
            case .legacyText, .empty:
                status = .noFolder
            }
        } catch let error as ProfileKnowledgeError {
            documentCount = 0
            totalBytes = 0
            estimatedTokens = 0
            fingerprint = ""
            keywords = []
            status = .error(Self.message(for: error))
        } catch {
            status = .error(String(describing: error))
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = loc("Выбрать")
        panel.message = loc("Папка с MD-файлами профиля")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await setFolder(url) }
    }

    func setFolder(_ url: URL) async {
        do {
            settingsStore.profileFolderBookmark = try ProfileFolderBookmark.make(for: url)
            settingsStore.profileSelectedPaths = nil
        } catch {
            status = .error(loc("Не удалось запомнить папку") + ": \(error.localizedDescription)")
            return
        }
        await reload()
    }

    func clearFolder() async {
        settingsStore.profileFolderBookmark = nil
        settingsStore.profileSelectedPaths = nil
        await reload()
    }

    func setSelected(_ path: String, _ isOn: Bool) async {
        var next = selectedPaths
        if isOn { next.insert(path) } else { next.remove(path) }
        settingsStore.profileSelectedPaths = next
        await reload()
    }

    func resetSelection() async {
        settingsStore.profileSelectedPaths = nil
        await reload()
    }

    func isSelected(_ path: String) -> Bool {
        selectedPaths.contains(path)
    }

    static func message(for error: ProfileKnowledgeError) -> String {
        switch error {
        case .folderUnavailable(let path):
            return loc("Папка профиля недоступна") + ": \(path)"
        case .unreadable(let path):
            return loc("Не удалось прочитать файл (нужен UTF-8)") + ": \(path)"
        case .tooLarge(let bytes, let limit):
            return loc("Профиль слишком большой") + ": \(formatBytes(bytes)) > \(formatBytes(limit)). " + loc("Снимите галочки с лишних файлов — обрезать молча мы не будем.")
        }
    }

    static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
