import Foundation

public enum RealtimeDigestSource: String, Sendable, Equatable {
    case file
    case cached
    case generated
    case legacy
    case none
}

public struct RealtimeDigest: Sendable, Equatable {
    public let text: String
    public let source: RealtimeDigestSource
    public let profileFingerprint: String?
    public let estimatedTokens: Int
    public let overBudget: Bool

    public init(text: String, source: RealtimeDigestSource, profileFingerprint: String?, estimatedTokens: Int, overBudget: Bool = false) {
        self.text = text
        self.source = source
        self.profileFingerprint = profileFingerprint
        self.estimatedTokens = estimatedTokens
        self.overBudget = overBudget
    }
}

public enum RealtimeDigestError: Error, Sendable, Equatable {
    case unavailable
    case noProfile
    case tooLong(estimatedTokens: Int, budget: Int)
    case generationFailed(String)
}

public protocol RealtimeDigestGenerating: Sendable {
    func isAvailable() async -> Bool
    func generateDigest(from snapshot: ProfileSnapshot, tokenBudget: Int, attempt: Int) async throws -> String
}

public protocol SessionInstructionRecording: Sendable {
    func setInstructionProfile(sessionID: SessionID, profile: InstructionProfile, digestSource: RealtimeDigestSource) async throws
    func instructionProfile(sessionID: SessionID) async throws -> InstructionProfile?
}

public actor SessionInstructionsFreezer {
    private let recorder: (any SessionInstructionRecording)?
    private var frozen: [SessionID: String] = [:]
    private let redactedLog: @Sendable (String) -> Void

    public init(recorder: (any SessionInstructionRecording)?, redactedLog: @escaping @Sendable (String) -> Void = { _ in }) {
        self.recorder = recorder
        self.redactedLog = redactedLog
    }

    public func instructions(for sessionID: SessionID?, build: @Sendable () async -> (profile: InstructionProfile, digestSource: RealtimeDigestSource, text: String)) async -> String {
        if let sessionID, let existing = frozen[sessionID] { return existing }
        let built = await build()
        guard let sessionID else { return built.text }
        if let existing = frozen[sessionID] { return existing }
        frozen[sessionID] = built.text
        do {
            try await recorder?.setInstructionProfile(sessionID: sessionID, profile: built.profile, digestSource: built.digestSource)
        } catch {
            redactedLog("instruction profile write failed: \(error)")
        }
        return built.text
    }

    public func forget(_ sessionID: SessionID) {
        frozen[sessionID] = nil
    }
}
