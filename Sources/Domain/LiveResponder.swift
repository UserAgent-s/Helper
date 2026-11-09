public enum InjectedContext: Sendable, Equatable {
    case me(String)
    case screen(application: String?, text: String)
    case note(String)

    public var text: String {
        switch self {
        case .me(let text), .note(let text): text
        case .screen(_, let text): text
        }
    }
}

public protocol LiveResponder: Sendable {
    var capabilities: ProviderCapabilities { get }
    func start(instructions: String) async throws
    func appendAudio(_ frame: PCMAudioFrame) async
    func events() -> AsyncStream<RealtimeAnswerEvent>
    func injectContext(_ context: InjectedContext) async throws
    func forceResponse() async throws
    func resetContext() async
    func stop() async
}

extension LiveResponder {
    public func injectContext(_ text: String) async throws {
        try await injectContext(.note(text))
    }
}
