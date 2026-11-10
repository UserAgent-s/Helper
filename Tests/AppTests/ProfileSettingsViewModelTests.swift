import Domain
import Foundation
import ProfileKnowledge
import Testing
@testable import UserAgent057

@MainActor
@Suite struct ProfileSettingsViewModelTests {
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("profile-vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("CV"), withIntermediateDirectories: true)
        try Data("# About Symfony".utf8).write(to: url.appendingPathComponent("01_ABOUT.md"))
        try Data("# Current".utf8).write(to: url.appendingPathComponent("02_CURRENT.md"))
        try Data("# CV".utf8).write(to: url.appendingPathComponent("CV/cv.md"))
        return url
    }

    private func make(limits: ProfileLimits = .standard) -> (ProfileSettingsViewModel, AppSettingsStore) {
        let store = AppSettingsStore(defaults: UserDefaults(suiteName: "profile-vm-\(UUID().uuidString)")!)
        let provider = MarkdownFolderProfileProvider(
            limits: limits,
            configuration: { store.profileFolderConfiguration() },
            legacyText: { store.backgroundContext }
        )
        return (ProfileSettingsViewModel(settingsStore: store, provider: provider, limits: limits), store)
    }

    @Test func noFolderUsesLegacyAndShowsNoError() async {
        let (viewModel, _) = make()
        await viewModel.reload()
        #expect(viewModel.status == .noFolder)
        #expect(viewModel.folderPath == nil)
        #expect(viewModel.candidates.isEmpty)
    }

    @Test func choosingFolderListsFilesWithDefaultSelection() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (viewModel, store) = make()
        await viewModel.setFolder(folder)
        #expect(store.profileFolderBookmark != nil)
        #expect(viewModel.candidates.map(\.relativePath) == ["01_ABOUT.md", "02_CURRENT.md", "CV/cv.md"])
        #expect(viewModel.selectedPaths == ["01_ABOUT.md", "02_CURRENT.md"])
        #expect(viewModel.usesDefaultSelection)
        #expect(viewModel.status == .ok)
        #expect(viewModel.documentCount == 2)
        #expect(viewModel.keywords.contains("Symfony"))

        await viewModel.setSelected("CV/cv.md", true)
        #expect(store.profileSelectedPaths == ["01_ABOUT.md", "02_CURRENT.md", "CV/cv.md"])
        #expect(viewModel.documentCount == 3)
        #expect(!viewModel.usesDefaultSelection)

        await viewModel.resetSelection()
        #expect(store.profileSelectedPaths == nil)
        #expect(viewModel.documentCount == 2)

        await viewModel.clearFolder()
        #expect(store.profileFolderBookmark == nil)
        #expect(viewModel.status == .noFolder)
    }

    @Test func overLimitShowsExplicitError() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (viewModel, _) = make(limits: ProfileLimits(warningBytes: 10, maxBytes: 20))
        await viewModel.setFolder(folder)
        guard case .error(let message) = viewModel.status else {
            Issue.record("expected error, got \(viewModel.status)")
            return
        }
        #expect(message.contains("24"))
        #expect(viewModel.documentCount == 0)
        #expect(viewModel.candidates.count == 3)
    }

    @Test func warningAboveSoftLimit() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (viewModel, _) = make(limits: ProfileLimits(warningBytes: 10, maxBytes: 1_000))
        await viewModel.setFolder(folder)
        #expect(viewModel.status == .warning)
    }
}
