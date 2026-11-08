import CryptoKit
import Domain
import Foundation

struct LegacyBackgroundProfileProvider: ProfileKnowledgeProviding {
    private let backgroundText: @Sendable () -> String

    init(backgroundText: @escaping @Sendable () -> String) {
        self.backgroundText = backgroundText
    }

    func realtimeDigest() async -> String {
        backgroundText()
    }

    func fingerprint() async -> String {
        let digest = SHA256.hash(data: Data(backgroundText().utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
