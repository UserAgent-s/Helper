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

public struct ExpertDomain: Sendable, Equatable {
    public let name: String
    public let role: String?
    public let documents: [ProfileDocument]

    public init(name: String, role: String?, documents: [ProfileDocument]) {
        self.name = name
        self.role = role
        self.documents = documents
    }

    public var byteCount: Int {
        (role?.utf8.count ?? 0) + documents.reduce(0) { $0 + $1.byteCount }
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
    public let domainMaxBytes: Int

    public init(warningBytes: Int = 100 * 1024, maxBytes: Int = 256 * 1024, domainMaxBytes: Int = 256 * 1024) {
        self.warningBytes = warningBytes
        self.maxBytes = maxBytes
        self.domainMaxBytes = domainMaxBytes
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
    public let domains: [ExpertDomain]

    public init(source: ProfileSource, documents: [ProfileDocument], fingerprint: String, estimatedTokens: Int, sizeStatus: ProfileSizeStatus, domains: [ExpertDomain] = []) {
        self.source = source
        self.documents = documents
        self.domains = domains
        self.fingerprint = fingerprint
        self.totalBytes = documents.reduce(0) { $0 + $1.byteCount }
        self.estimatedTokens = estimatedTokens
        self.sizeStatus = sizeStatus
    }

    public var isEmpty: Bool { documents.isEmpty }

    public var hasContent: Bool { !documents.isEmpty || !domains.isEmpty }
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
