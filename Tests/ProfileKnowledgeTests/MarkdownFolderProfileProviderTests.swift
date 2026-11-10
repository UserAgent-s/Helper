import Domain
import Foundation
import Testing
@testable import ProfileKnowledge

private final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _config: ProfileFolderConfiguration
    private var _legacy: String

    init(folder: URL?, selected: Set<String>? = nil, legacy: String = "") {
        _config = ProfileFolderConfiguration(folder: folder, selectedPaths: selected)
        _legacy = legacy
    }

    var config: ProfileFolderConfiguration {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue } }
    }

    var legacy: String {
        get { lock.withLock { _legacy } }
        set { lock.withLock { _legacy = newValue } }
    }
}

@Suite struct MarkdownFolderProfileProviderTests {
    private func provider(_ box: ConfigBox, limits: ProfileLimits = .standard) -> MarkdownFolderProfileProvider {
        MarkdownFolderProfileProvider(limits: limits, configuration: { box.config }, legacyText: { box.legacy })
    }

    @Test func scanFiltersExtensionsDepthAndHiddenAndSortsByPath() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        try folder.write("02_CURRENT_PROFILE.md", "b")
        try folder.write("01_ABOUT_ME.md", "a")
        try folder.write("00_START_HERE.MD", "z")
        try folder.write("MANIFEST.json", "{}")
        try folder.write("notes.txt", "x")
        try folder.write("CV/cv.md", "cv")
        try folder.write("CV/cv.pdf", "pdf")
        try folder.write("Sources/deep/too-deep.md", "deep")
        try folder.write(".hidden.md", "h")
        try folder.write(".git/HEAD.md", "h")
        let paths = try ProfileFolderScanner.scan(folder.url).map(\.relativePath)
        #expect(paths == ["00_START_HERE.MD", "01_ABOUT_ME.md", "02_CURRENT_PROFILE.md", "CV/cv.md"])
    }

    @Test func defaultSelectionIsCanonicalTopLevelFiles() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        for name in ["00_START_HERE.md", "01_ABOUT_ME_ALL_IN_ONE.md", "02_CURRENT_PROFILE.md", "03_OPEN_QUESTIONS.md", "CV/Full_CV.md", "Sources/history.md"] {
            try folder.write(name, "# \(name)")
        }
        let snapshot = try await snap(provider(ConfigBox(folder: folder.url)))
        #expect(snapshot.documents.map(\.relativePath) == ["01_ABOUT_ME_ALL_IN_ONE.md", "02_CURRENT_PROFILE.md", "03_OPEN_QUESTIONS.md"])
        #expect(snapshot.source == .markdownFolder(path: folder.url.path))
    }

    @Test func defaultSelectionFallsBackToAllTopLevelWhenNoCanonicalFiles() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        try folder.write("me.md", "a")
        try folder.write("work.md", "b")
        try folder.write("sub/extra.md", "c")
        let snapshot = try await snap(provider(ConfigBox(folder: folder.url)))
        #expect(snapshot.documents.map(\.relativePath) == ["me.md", "work.md"])
    }

    @Test func explicitSelectionIsHonouredAndKeepsPathOrder() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        try folder.write("01_a.md", "a")
        try folder.write("CV/cv.md", "cv")
        try folder.write("02_b.md", "b")
        let box = ConfigBox(folder: folder.url, selected: ["CV/cv.md", "01_a.md", "missing.md"])
        let snapshot = try await snap(provider(box))
        #expect(snapshot.documents.map(\.relativePath) == ["01_a.md", "CV/cv.md"])
    }

    @Test func stripsBOMAndNormalizesToNFC() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        let decomposed = "Опыт: И\u{0306}о и cafe\u{0301}"
        try folder.write("01_a.md", Data([0xEF, 0xBB, 0xBF]) + Data(decomposed.utf8))
        let snapshot = try await snap(provider(ConfigBox(folder: folder.url)))
        let text = try #require(snapshot.documents.first?.text)
        #expect(!text.hasPrefix("\u{FEFF}"))
        #expect(text == decomposed.precomposedStringWithCanonicalMapping)
        #expect(text.unicodeScalars.contains("\u{00E9}"))
        #expect(text.unicodeScalars.contains("\u{0419}"))
    }

    @Test func nfcAndNFDContentShareFingerprint() async throws {
        let nfc = try ProfileTestFolder()
        let nfd = try ProfileTestFolder()
        defer { nfc.remove(); nfd.remove() }
        try nfc.write("01_a.md", "café Йошкар")
        try nfd.write("01_a.md", "café Йошкар".decomposedStringWithCanonicalMapping)
        let a = try await snap(provider(ConfigBox(folder: nfc.url)))
        let b = try await snap(provider(ConfigBox(folder: nfd.url)))
        #expect(a.fingerprint == b.fingerprint)
    }

    @Test func fingerprintIsStableAndChangesOnlyWithContent() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        try folder.write("01_a.md", "alpha")
        try folder.write("02_b.md", "beta")
        let p = provider(ConfigBox(folder: folder.url))
        let first = try await snap(p)
        let second = try await snap(p)
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.fingerprint.count == 64)
        try folder.write("notes.txt", "ignored")
        try folder.write("CV/unselected.md", "ignored")
        #expect(try await snap(p).fingerprint == first.fingerprint)
        try folder.write("02_b.md", "beta!")
        let changed = try await snap(p)
        #expect(changed.fingerprint != first.fingerprint)
        #expect(changed.documents.last?.text == "beta!")
    }

    @Test func fingerprintDistinguishesFileBoundaries() async throws {
        let one = try ProfileTestFolder()
        let two = try ProfileTestFolder()
        defer { one.remove(); two.remove() }
        try one.write("01_a.md", "ab")
        try one.write("02_b.md", "c")
        try two.write("01_a.md", "a")
        try two.write("02_b.md", "bc")
        let a = try await snap(provider(ConfigBox(folder: one.url)))
        let b = try await snap(provider(ConfigBox(folder: two.url)))
        #expect(a.fingerprint != b.fingerprint)
    }

    @Test func warnsAboveWarningLimitAndFailsAboveMaxWithoutTruncating() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        try folder.write("01_a.md", String(repeating: "a", count: 600))
        let limits = ProfileLimits(warningBytes: 500, maxBytes: 1_000)
        let box = ConfigBox(folder: folder.url)
        let warned = try await snap(provider(box, limits: limits))
        #expect(warned.sizeStatus == .warning)
        #expect(warned.totalBytes == 600)
        try folder.write("02_b.md", String(repeating: "b", count: 300))
        try folder.write("03_c.md", String(repeating: "c", count: 300))
        await #expect(throws: ProfileKnowledgeError.tooLarge(bytes: 1_200, limit: 1_000)) {
            try await snap(provider(box, limits: limits))
        }
        try folder.write("01_a.md", "small")
        let recovered = try await snap(provider(box, limits: limits))
        #expect(recovered.totalBytes == 605)
        #expect(recovered.sizeStatus == .warning)
        try folder.write("02_b.md", "b")
        try folder.write("03_c.md", "c")
        #expect(try await snap(provider(box, limits: limits)).sizeStatus == .ok)
    }

    @Test func rereadsChangesWithoutRestart() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        try folder.write("01_a.md", "v1")
        let p = provider(ConfigBox(folder: folder.url))
        #expect(try await snap(p).documents.map(\.text) == ["v1"])
        try folder.write("01_a.md", "v2")
        try folder.write("02_b.md", "new")
        #expect(try await snap(p).documents.map(\.text) == ["v2", "new"])
    }

    @Test func withoutFolderFallsBackToLegacyBackground() async throws {
        let box = ConfigBox(folder: nil, legacy: "  Senior PHP, Symfony  ")
        let p = provider(box)
        let snapshot = try await snap(p)
        #expect(snapshot.source == .legacyText)
        #expect(snapshot.documents.map(\.text) == ["Senior PHP, Symfony"])
        box.legacy = ""
        let empty = try await snap(p)
        #expect(empty.source == .empty)
        #expect(empty.isEmpty)
        #expect(empty.fingerprint.count == 64)
    }

    @Test func missingFolderIsAnExplicitErrorNotAFallback() async throws {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        let box = ConfigBox(folder: gone, legacy: "legacy")
        await #expect(throws: ProfileKnowledgeError.folderUnavailable(path: gone.path)) {
            try await snap(provider(box))
        }
    }

    @Test func nonUTF8FileIsReportedByPath() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        try folder.write("01_a.md", Data([0xFF, 0xFE, 0x00, 0xD8]))
        await #expect(throws: ProfileKnowledgeError.unreadable(relativePath: "01_a.md")) {
            try await snap(provider(ConfigBox(folder: folder.url)))
        }
    }

    @Test func realtimeDigestStaysLegacyAndRelevantContextIsWholeProfile() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        try folder.write("01_a.md", "a")
        try folder.write("02_b.md", "b")
        let p = provider(ConfigBox(folder: folder.url, legacy: "legacy"))
        #expect(await p.realtimeDigest() == "legacy")
        #expect(try await p.relevantContext(for: "anything", tokenBudget: 1).map(\.relativePath) == ["01_a.md", "02_b.md"])
    }

    @Test func transcriptionKeywordsComeFromProfile() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        try folder.write("01_a.md", "Работал с Symfony и Kubernetes. Symfony 6, PHP 8.3, RedCore. и обычные слова.")
        let keywords = await provider(ConfigBox(folder: folder.url)).transcriptionKeywords()
        #expect(keywords.first == "Symfony")
        #expect(keywords.contains("Kubernetes"))
        #expect(keywords.contains("RedCore"))
        #expect(keywords.contains("PHP"))
        #expect(!keywords.contains("и"))
    }

    @Test func tokenEstimateCountsCyrillicDenser() {
        #expect(ProfileTokenEstimator.estimate("abcdefgh") == 2)
        #expect(ProfileTokenEstimator.estimate("абвгдеёж") == 4)
        #expect(ProfileTokenEstimator.estimate("") == 0)
    }

    @Test func bookmarkRoundTripsFolder() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        let data = try ProfileFolderBookmark.make(for: folder.url)
        let resolved = try #require(ProfileFolderBookmark.resolve(data))
        #expect(resolved.url.standardizedFileURL.resolvingSymlinksInPath().path == folder.url.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    private func snap(_ provider: MarkdownFolderProfileProvider) async throws -> ProfileSnapshot {
        try await provider.snapshot()
    }
}
