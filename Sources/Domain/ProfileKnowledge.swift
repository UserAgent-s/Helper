import Foundation

public struct ProfileDocument: Sendable, Equatable {
    public let relativePath: String
    public let text: String
    public let byteCount: Int

    public init(relativePath: String, text: String) {
        self.relativePath = relativePath
        self.text = text
        self.byteCount = text.utf8.count
    }
}

public enum ProfileSource: Sendable, Equatable {
    case markdownFolder(path: String)
    case legacyText
    case empty
}

public enum ProfileSizeStatus: Sendable, Equatable {
    case ok
    case warning
}

public struct ProfileLimits: Sendable, Equatable {
    public let warningBytes: Int
    public let maxBytes: Int

    public init(warningBytes: Int = 100 * 1024, maxBytes: Int = 256 * 1024) {
        self.warningBytes = warningBytes
        self.maxBytes = maxBytes
    }

    public static let standard = ProfileLimits()
}

public struct ProfileSnapshot: Sendable, Equatable {
    public let source: ProfileSource
    public let documents: [ProfileDocument]
    public let fingerprint: String
    public let totalBytes: Int
    public let estimatedTokens: Int
    public let sizeStatus: ProfileSizeStatus

    public init(source: ProfileSource, documents: [ProfileDocument], fingerprint: String, estimatedTokens: Int, sizeStatus: ProfileSizeStatus) {
        self.source = source
        self.documents = documents
        self.fingerprint = fingerprint
        self.totalBytes = documents.reduce(0) { $0 + $1.byteCount }
        self.estimatedTokens = estimatedTokens
        self.sizeStatus = sizeStatus
    }

    public var isEmpty: Bool { documents.isEmpty }
}

public enum ProfileKnowledgeError: Error, Sendable, Equatable {
    case folderUnavailable(path: String)
    case unreadable(relativePath: String)
    case tooLarge(bytes: Int, limit: Int)
}

public protocol ProfileKnowledgeProviding: Sendable {
    func snapshot() async throws -> ProfileSnapshot
    func realtimeDigest() async -> String
    func relevantContext(for query: String, tokenBudget: Int) async throws -> [ProfileDocument]
    func transcriptionKeywords() async -> [String]
}

extension ProfileKnowledgeProviding {
    public func fingerprint() async -> String {
        (try? await snapshot().fingerprint) ?? ""
    }
}
