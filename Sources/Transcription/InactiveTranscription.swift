import Domain

public struct InactiveLocalTranscribing: LocalTranscribing {
    public init() {}

    public func transcribe(_ frames: [PCMAudioFrame]) async throws -> [TranscribedSegment] {
        guard frames.isEmpty else {
            throw BootstrapUnavailableError.notYetImplemented("LocalTranscribing (WhisperKit) подключается на этапах 06/07")
        }
        return []
    }
}
