import Domain

public struct WhisperKitFragmentRecognizer: SpeechFragmentRecognizing {
    private let transcriber: WhisperKitTranscribing

    public init(transcriber: WhisperKitTranscribing) {
        self.transcriber = transcriber
    }

    public func prepare() async throws {
        try await transcriber.prewarm()
    }

    public func recognize(_ frames: [PCMAudioFrame]) async throws -> String {
        let segments = try await transcriber.transcribe(frames)
        return segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
