import Domain
import Foundation
import Testing
@testable import ProfileKnowledge

private actor FakeGenerator: RealtimeDigestGenerating {
    var available = true
    var outputs: [String]
    private(set) var attempts: [Int] = []

    init(outputs: [String]) { self.outputs = outputs }

    func isAvailable() -> Bool { available }
    func setAvailable(_ value: Bool) { available = value }

    func generateDigest(from snapshot: ProfileSnapshot, tokenBudget: Int, attempt: Int) throws -> String {
        attempts.append(attempt)
        return outputs.isEmpty ? "" : outputs.removeFirst()
    }
}

@Suite struct RealtimeDigestStoreTests {
    private func make(_ folder: ProfileTestFolder, generator: FakeGenerator?, cache: URL, legacy: String = "legacy bg", budget: Int = 100) -> RealtimeDigestStore {
        let config = ProfileFolderConfiguration(folder: folder.url, selectedPaths: nil)
        let provider = MarkdownFolderProfileProvider(configuration: { config }, legacyText: { legacy })
        return RealtimeDigestStore(configuration: { config }, snapshot: { try await provider.snapshot() }, legacyText: { legacy }, cacheDirectory: cache, generator: generator, budget: budget)
    }

    private func cacheDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("digest-cache-\(UUID().uuidString)")
    }

    @Test func realtimeFileIsUsedVerbatimAndClaudeIsNotCalled() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        try folder.write("01_a.md", "profile")
        try folder.write("00-realtime.md", "\u{FEFF}  Моя выжимка: PHP, Symfony  \n")
        let generator = FakeGenerator(outputs: ["generated"])
        let store = make(folder, generator: generator, cache: cacheDir())
        let digest = await store.current()
        #expect(digest.source == .file)
        #expect(digest.text == "Моя выжимка: PHP, Symfony")
        #expect(try await store.generateNow().source == .file)
        await store.waitForGeneration()
        #expect(await generator.attempts.isEmpty)
    }

    @Test func overBudgetFileIsStillVerbatimButFlagged() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        try folder.write("00-realtime.md", String(repeating: "word ", count: 200))
        let digest = await make(folder, generator: nil, cache: cacheDir(), budget: 50).current()
        #expect(digest.source == .file)
        #expect(digest.overBudget)
    }

    @Test func generatesInBackgroundThenServesFromCacheByFingerprint() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        try folder.write("01_a.md", "Senior PHP")
        let cache = cacheDir()
        defer { try? FileManager.default.removeItem(at: cache) }
        let generator = FakeGenerator(outputs: ["Выжимка v1", "Выжимка v2"])
        let store = make(folder, generator: generator, cache: cache)
        let first = await store.current()
        #expect(first.source == .legacy)
        #expect(first.text == "legacy bg")
        await store.waitForGeneration()
        let second = await store.current()
        #expect(second.source == .cached)
        #expect(second.text == "Выжимка v1")
        #expect(await generator.attempts == [1])

        let reopened = make(folder, generator: generator, cache: cache)
        #expect(await reopened.current().text == "Выжимка v1")
        #expect(await generator.attempts == [1])

        try folder.write("01_a.md", "Senior PHP, Go")
        #expect(await store.current().source == .legacy)
        await store.waitForGeneration()
        #expect(await store.current().text == "Выжимка v2")
        #expect(await generator.attempts == [1, 1])
    }

    @Test func withoutKeyFallsBackToLegacyAndNeverGenerates() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        try folder.write("01_a.md", "Senior PHP")
        let generator = FakeGenerator(outputs: ["x"])
        await generator.setAvailable(false)
        let store = make(folder, generator: generator, cache: cacheDir())
        #expect(await store.current() == RealtimeDigest(text: "legacy bg", source: .legacy, profileFingerprint: nil, estimatedTokens: 3))
        await #expect(throws: RealtimeDigestError.unavailable) { try await store.generateNow() }
        #expect(await generator.attempts.isEmpty)
        let empty = make(folder, generator: nil, cache: cacheDir(), legacy: "  ")
        #expect(await empty.current().source == .none)
    }

    @Test func budgetRetriesOnceThenFailsWithoutCaching() async throws {
        let folder = try ProfileTestFolder()
        defer { folder.remove() }
        try folder.write("01_a.md", "Senior PHP")
        let long = String(repeating: "abcd ", count: 200)
        let retried = FakeGenerator(outputs: [long, "короткая"])
        let ok = try await make(folder, generator: retried, cache: cacheDir(), budget: 100).generateNow()
        #expect(ok.text == "короткая")
        #expect(ok.source == .generated)
        #expect(await retried.attempts == [1, 2])

        let cache = cacheDir()
        let failing = FakeGenerator(outputs: [long, long])
        let store = make(folder, generator: failing, cache: cache, budget: 100)
        await #expect(throws: RealtimeDigestError.tooLong(estimatedTokens: ProfileTokenEstimator.estimate(long.trimmingCharacters(in: .whitespacesAndNewlines)), budget: 100)) {
            try await store.generateNow()
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: cache.path))?.isEmpty ?? true)
    }

    @Test func legacyOnlyProfileIsNotSentToGenerator() async throws {
        let generator = FakeGenerator(outputs: ["x"])
        let config = ProfileFolderConfiguration(folder: nil, selectedPaths: nil)
        let provider = MarkdownFolderProfileProvider(configuration: { config }, legacyText: { "bg" })
        let store = RealtimeDigestStore(configuration: { config }, snapshot: { try await provider.snapshot() }, legacyText: { "bg" }, cacheDirectory: cacheDir(), generator: generator)
        #expect(await store.current().source == .legacy)
        await #expect(throws: RealtimeDigestError.noProfile) { try await store.generateNow() }
        await store.waitForGeneration()
        #expect(await generator.attempts.isEmpty)
    }
}
