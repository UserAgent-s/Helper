public protocol ModeController: Sendable {
    func start() async throws
    func stop() async

    func failures() -> AsyncStream<String>
}
