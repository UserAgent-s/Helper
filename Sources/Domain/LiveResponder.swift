public protocol LiveResponder: Sendable {
    var capabilities: ProviderCapabilities { get }
    func start(instructions: String) async throws
    func appendAudio(_ frame: PCMAudioFrame) async
    func events() -> AsyncStream<RealtimeAnswerEvent>
    func injectContext(_ text: String) async throws
    func forceResponse() async throws
    func resetContext() async
    func stop() async
}
