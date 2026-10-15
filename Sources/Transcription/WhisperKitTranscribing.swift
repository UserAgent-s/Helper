import Domain
import WhisperKit

public actor WhisperKitTranscribing: LocalTranscribing {
    private let modelID: String
    private var loadedWhisperKit: WhisperKit?

    public init(modelID: String = WhisperModelCatalog.defaultModelID) {
        self.modelID = modelID
    }

    @discardableResult
    public func prewarm() async throws -> Bool {
        _ = try await whisperKit()
        return true
    }

    public func transcribe(_ frames: [PCMAudioFrame]) async throws -> [TranscribedSegment] {
        guard !frames.isEmpty else { return [] }
        let source: TranscriptSource = frames.first?.source == .microphone ? .local : .remote
        let audioArray = Self.floatSamples(from: frames)
        let kit = try await whisperKit()
        let results = try await kit.transcribe(
            audioArray: audioArray,
            decodeOptions: DecodingOptions(detectLanguage: true, chunkingStrategy: .vad)
        )
        return results.flatMap { result in
            result.segments.compactMap { segment -> TranscribedSegment? in
                guard !Self.isLikelyHallucinated(segment) else { return nil }
                let text = Self.stripSpecialTokens(segment.text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !Self.isNonSpeechAnnotation(text) else { return nil }
                return TranscribedSegment(
                    text: text,
                    startMs: Int(segment.start * 1000),
                    endMs: Int(segment.end * 1000),
                    source: source,
                    language: result.language
                )
            }
        }
    }

    static func stripSpecialTokens(_ text: String) -> String {
        var result = ""
        var remainder = Substring(text)
        while let openRange = remainder.range(of: "<|"), let closeRange = remainder.range(of: "|>", range: openRange.upperBound..<remainder.endIndex) {
            result += remainder[remainder.startIndex..<openRange.lowerBound]
            remainder = remainder[closeRange.upperBound...]
        }
        result += remainder
        return result
    }

    static func isLikelyHallucinated(_ segment: TranscriptionSegment) -> Bool {
        if segment.noSpeechProb > 0.6, segment.avgLogprob < -1.0 { return true }
        if segment.compressionRatio > 2.4 { return true }
        return false
    }

    static func isNonSpeechAnnotation(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return false }
        return (first == "[" && last == "]") || (first == "(" && last == ")")
    }

    private func whisperKit() async throws -> WhisperKit {
        if let loadedWhisperKit { return loadedWhisperKit }
        let kit = try await WhisperKit(WhisperKitConfig(model: modelID))
        loadedWhisperKit = kit
        return kit
    }

    private static func floatSamples(from frames: [PCMAudioFrame]) -> [Float] {
        frames.flatMap { frame in frame.samples.map { Float($0) / Float(Int16.max) } }
    }
}
