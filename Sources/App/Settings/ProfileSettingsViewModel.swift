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
    private let digestStore: RealtimeDigestStore?

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
    private(set) var digest: RealtimeDigest?
    private(set) var digestError: String?
    private(set) var isGeneratingDigest = false

    init(settingsStore: AppSettingsStore, provider: MarkdownFolderProfileProvider, limits: ProfileLimits = .standard, digestStore: RealtimeDigestStore? = nil) {
        self.digestStore = digestStore
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
            await refreshDigest()
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

    func refreshDigest() async {
        guard let digestStore else { return }
        digest = await digestStore.current(generateInBackground: false)
    }

    func generateDigest() async {
        guard let digestStore, !isGeneratingDigest else { return }
        isGeneratingDigest = true
        digestError = nil
        do {
            digest = try await digestStore.generateNow()
        } catch let error as RealtimeDigestError {
            digestError = Self.message(for: error)
        } catch {
            digestError = String(describing: error)
        }
        isGeneratingDigest = false
    }

    var digestStatusText: String {
        guard let digest else { return "" }
        let tokens = String(format: loc("≈%d токенов"), digest.estimatedTokens)
        switch digest.source {
        case .file: return loc("Выжимка для живых ответов: файл 00-realtime.md") + " · " + tokens + (digest.overBudget ? " · " + loc("больше 4000 токенов") : "")
        case .cached, .generated: return loc("Выжимка для живых ответов: сгенерирована Claude") + " · " + tokens
        case .legacy: return loc("Выжимка для живых ответов: текст «Опыт работы»") + " · " + tokens
        case .none: return loc("Выжимки для живых ответов нет")
        }
    }

    static func message(for error: RealtimeDigestError) -> String {
        switch error {
        case .unavailable: return loc("Нужен ключ Anthropic")
        case .noProfile: return loc("Сначала выберите папку профиля")
        case .tooLong(let tokens, let budget): return String(format: loc("Claude вернул слишком длинную выжимку (≈%d из %d токенов)"), tokens, budget)
        case .generationFailed(let code): return loc("Не удалось сгенерировать выжимку") + ": \(code)"
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
