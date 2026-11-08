import Domain

public struct InactiveRealtimeAnswering: RealtimeAnswering {
    public init() {}

    public func start(instructions: String) async throws {
        throw BootstrapUnavailableError.notYetImplemented("RealtimeAnswering подключается на этапе 04")
    }

    public func appendAudio(_ frame: PCMAudioFrame) async {}

    public func events() -> AsyncStream<RealtimeAnswerEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    public func forceResponse() async throws {
        throw BootstrapUnavailableError.notYetImplemented("RealtimeAnswering подключается на этапе 04")
    }

    public func stop() async {}
}
