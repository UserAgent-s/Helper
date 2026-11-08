public actor ManualAnswerTrigger: AnswerTriggering {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    public init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    nonisolated public func events() -> AsyncStream<Void> {
        stream
    }

    public func fire() {
        continuation.yield(())
    }
}
