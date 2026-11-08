public protocol ProfileKnowledgeProviding: Sendable {
    func realtimeDigest() async -> String
    func fingerprint() async -> String
}
