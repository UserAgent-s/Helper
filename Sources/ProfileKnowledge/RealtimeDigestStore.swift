import CryptoKit
import Domain
import Foundation

public actor RealtimeDigestStore {
    public static let fileName = "00-realtime.md"
    public static let tokenBudget = 4_000
    public static let generatorVersion = 1

    private let configuration: @Sendable () -> ProfileFolderConfiguration
    private let snapshot: @Sendable () async throws -> ProfileSnapshot
    private let legacyText: @Sendable () -> String
    private let cacheDirectory: URL
    private let generator: (any RealtimeDigestGenerating)?
    private let budget: Int
    private let redactedLog: @Sendable (String) -> Void
    private var inFlight: [String: Task<RealtimeDigest, any Error>] = [:]
    private(set) var generationCount = 0

    public init(
        configuration: @escaping @Sendable () -> ProfileFolderConfiguration,
        snapshot: @escaping @Sendable () async throws -> ProfileSnapshot,
        legacyText: @escaping @Sendable () -> String,
        cacheDirectory: URL,
        generator: (any RealtimeDigestGenerating)?,
        budget: Int = RealtimeDigestStore.tokenBudget,
        redactedLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.snapshot = snapshot
        self.legacyText = legacyText
        self.cacheDirectory = cacheDirectory
        self.generator = generator
        self.budget = budget
        self.redactedLog = redactedLog
    }

    public func current(generateInBackground: Bool = true) async -> RealtimeDigest {
        if let file = fileDigest() { return file }
        if let profile = try? await snapshot(), case .markdownFolder = profile.source, !profile.isEmpty {
            let key = Self.cacheKey(profile.fingerprint)
            if let cached = readCache(key, fingerprint: profile.fingerprint) { return cached }
            if generateInBackground, let generator, await generator.isAvailable() {
                _ = startGeneration(profile, key: key)
            }
        }
        return legacyDigest()
    }

    public func generateNow() async throws -> RealtimeDigest {
        if let file = fileDigest() { return file }
        guard let generator, await generator.isAvailable() else { throw RealtimeDigestError.unavailable }
        let profile = try await snapshot()
        guard case .markdownFolder = profile.source, !profile.isEmpty else { throw RealtimeDigestError.noProfile }
        let key = Self.cacheKey(profile.fingerprint)
        if let cached = readCache(key, fingerprint: profile.fingerprint) { return cached }
        return try await startGeneration(profile, key: key).value
    }

    public func waitForGeneration() async {
        for task in inFlight.values { _ = try? await task.value }
    }

    private func startGeneration(_ profile: ProfileSnapshot, key: String) -> Task<RealtimeDigest, any Error> {
        if let running = inFlight[key] { return running }
        generationCount += 1
        let generator = self.generator
        let budget = self.budget
        let task = Task<RealtimeDigest, any Error> { [weak self] in
            guard let generator else { throw RealtimeDigestError.unavailable }
            var lastTokens = 0
            for attempt in 1...2 {
                let raw = try await generator.generateDigest(from: profile, tokenBudget: budget, attempt: attempt)
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
                let tokens = ProfileTokenEstimator.estimate(text)
                lastTokens = tokens
                guard !text.isEmpty, tokens <= budget else { continue }
                let digest = RealtimeDigest(text: text, source: .generated, profileFingerprint: profile.fingerprint, estimatedTokens: tokens)
                await self?.writeCache(key, text: text)
                return digest
            }
            throw RealtimeDigestError.tooLong(estimatedTokens: lastTokens, budget: budget)
        }
        inFlight[key] = task
        Task { [weak self] in
            let result = await task.result
            await self?.finished(key, result)
        }
        return task
    }

    private func finished(_ key: String, _ result: Result<RealtimeDigest, any Error>) {
        inFlight[key] = nil
        if case .failure(let error) = result { redactedLog("realtime digest generation failed: \(error)") }
    }

    private func fileDigest() -> RealtimeDigest? {
        guard let folder = configuration().folder else { return nil }
        let url = folder.appendingPathComponent(Self.fileName)
        guard let data = try? Data(contentsOf: url), let text = MarkdownFolderProfileProvider.decode(data) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = ProfileTokenEstimator.estimate(trimmed)
        return RealtimeDigest(text: trimmed, source: .file, profileFingerprint: nil, estimatedTokens: tokens, overBudget: tokens > budget)
    }

    private func legacyDigest() -> RealtimeDigest {
        let text = legacyText().trimmingCharacters(in: .whitespacesAndNewlines)
        return RealtimeDigest(text: text, source: text.isEmpty ? .none : .legacy, profileFingerprint: nil, estimatedTokens: ProfileTokenEstimator.estimate(text))
    }

    private func cacheURL(_ key: String) -> URL {
        cacheDirectory.appendingPathComponent("\(key).md")
    }

    private func readCache(_ key: String, fingerprint: String) -> RealtimeDigest? {
        guard let data = try? Data(contentsOf: cacheURL(key)), let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return RealtimeDigest(text: text, source: .cached, profileFingerprint: fingerprint, estimatedTokens: ProfileTokenEstimator.estimate(text))
    }

    private func writeCache(_ key: String, text: String) {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: cacheURL(key), options: .atomic)
        } catch {
            redactedLog("realtime digest cache write failed: \(error)")
        }
    }

    static func cacheKey(_ fingerprint: String) -> String {
        let digest = SHA256.hash(data: Data("v\(generatorVersion):\(fingerprint)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
