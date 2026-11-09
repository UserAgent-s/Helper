import Foundation

public struct TranscriptDelta: Sendable, Equatable {
    public let itemID: String
    public let text: String
    public let isFinal: Bool
    public let source: TranscriptSource
    public let language: String?

    public init(itemID: String, text: String, isFinal: Bool, source: TranscriptSource, language: String? = nil) {
        self.itemID = itemID
        self.text = text
        self.isFinal = isFinal
        self.source = source
        self.language = language
    }
}

public protocol StreamingTranscriber: Sendable {
    var capabilities: ProviderCapabilities { get }
    func start(language: String?) async throws -> AsyncStream<TranscriptDelta>
    func appendAudio(_ frame: PCMAudioFrame) async
    func stop() async
}

public enum MeTranscriptionStatus: Sendable, Equatable {
    case connecting
    case live
    case reconnecting(attempt: Int)
    case unavailable(reason: String)
    case stopped
}

public protocol MeTranscribing: Sendable {
    func start(languages: [String]) async throws -> AsyncStream<TranscriptDelta>
    func appendAudio(_ frame: PCMAudioFrame) async
    func commitTurn() async
    func statusUpdates() -> AsyncStream<MeTranscriptionStatus>
    func stop() async
}
