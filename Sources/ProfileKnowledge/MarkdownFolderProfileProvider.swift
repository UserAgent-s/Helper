import CryptoKit
import Domain
import Foundation

public struct ProfileFolderConfiguration: Sendable, Equatable {
    public let folder: URL?
    public let selectedPaths: Set<String>?

    public init(folder: URL?, selectedPaths: Set<String>?) {
        self.folder = folder
        self.selectedPaths = selectedPaths
    }
}

public actor MarkdownFolderProfileProvider: ProfileKnowledgeProviding {
    private let configuration: @Sendable () -> ProfileFolderConfiguration
    private let legacyText: @Sendable () -> String
    private let limits: ProfileLimits
    private var keywordCache: (fingerprint: String, keywords: [String])?

    public init(
        limits: ProfileLimits = .standard,
        configuration: @escaping @Sendable () -> ProfileFolderConfiguration,
        legacyText: @escaping @Sendable () -> String
    ) {
        self.limits = limits
        self.configuration = configuration
        self.legacyText = legacyText
    }

    public func candidates() throws -> [ProfileCandidate] {
        guard let folder = configuration().folder else { return [] }
        do {
            return try ProfileFolderScanner.scan(folder)
        } catch {
            throw ProfileKnowledgeError.folderUnavailable(path: folder.path)
        }
    }

    public func snapshot() throws -> ProfileSnapshot {
        let config = configuration()
        guard let folder = config.folder else { return legacySnapshot() }
        let candidates: [ProfileCandidate]
        do {
            candidates = try ProfileFolderScanner.scan(folder)
        } catch {
            throw ProfileKnowledgeError.folderUnavailable(path: folder.path)
        }
        let paths = ProfileSelection.effectivePaths(stored: config.selectedPaths, candidates: candidates)
        var documents: [ProfileDocument] = []
        var total = 0
        for path in paths {
            let url = folder.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else {
                throw ProfileKnowledgeError.unreadable(relativePath: path)
            }
            guard let text = Self.decode(data) else {
                throw ProfileKnowledgeError.unreadable(relativePath: path)
            }
            let document = ProfileDocument(relativePath: path, text: text)
            total += document.byteCount
            if total > limits.maxBytes {
                let rest = paths.drop { $0 != path }.dropFirst()
                let remaining = rest.reduce(0) { sum, p in sum + (candidates.first { $0.relativePath == p }?.byteCount ?? 0) }
                throw ProfileKnowledgeError.tooLarge(bytes: total + remaining, limit: limits.maxBytes)
            }
            documents.append(document)
        }
        return makeSnapshot(source: .markdownFolder(path: folder.path), documents: documents)
    }

    public func realtimeDigest() -> String {
        legacyText()
    }

    public func relevantContext(for query: String, tokenBudget: Int) throws -> [ProfileDocument] {
        try snapshot().documents
    }

    public func transcriptionKeywords() -> [String] {
        guard let snapshot = try? snapshot() else { return [] }
        if let cache = keywordCache, cache.fingerprint == snapshot.fingerprint { return cache.keywords }
        let keywords = ProfileKeywordExtractor.sanitized(ProfileKeywordExtractor.extract(from: snapshot.documents))
        keywordCache = (snapshot.fingerprint, keywords)
        return keywords
    }

    private func legacySnapshot() -> ProfileSnapshot {
        let text = legacyText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return makeSnapshot(source: .empty, documents: []) }
        return makeSnapshot(source: .legacyText, documents: [ProfileDocument(relativePath: "background.txt", text: text.precomposedStringWithCanonicalMapping)])
    }

    private func makeSnapshot(source: ProfileSource, documents: [ProfileDocument]) -> ProfileSnapshot {
        let total = documents.reduce(0) { $0 + $1.byteCount }
        return ProfileSnapshot(
            source: source,
            documents: documents,
            fingerprint: Self.fingerprint(documents),
            estimatedTokens: ProfileTokenEstimator.estimate(documents.map(\.text)),
            sizeStatus: total > limits.warningBytes ? .warning : .ok
        )
    }

    static func decode(_ data: Data) -> String? {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard var text = String(data: bytes, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.precomposedStringWithCanonicalMapping
    }

    static func fingerprint(_ documents: [ProfileDocument]) -> String {
        var hasher = SHA256()
        for document in documents {
            hasher.update(data: Data(document.relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(document.byteCount).utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(document.text.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
