import Domain

public struct InactiveLiveResponder: LiveResponder {
    public init() {}

    public var capabilities: ProviderCapabilities { [] }

    public func injectContext(_ text: String) async throws {
        throw ProviderSeamError.unsupported("textInjection")
    }

    public func start(instructions: String) async throws {
        throw BootstrapUnavailableError.notYetImplemented("LiveResponder подключается на этапе 04")
    }

    public func appendAudio(_ frame: PCMAudioFrame) async {}

    public func events() -> AsyncStream<RealtimeAnswerEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    public func forceResponse() async throws {
        throw BootstrapUnavailableError.notYetImplemented("LiveResponder подключается на этапе 04")
    }

    public func resetContext() async {}

    public func stop() async {}
}
