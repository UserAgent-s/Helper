import Foundation

public final class EventBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var latestElement: Element?
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    public init(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded, latest: Element? = nil) {
        self.bufferingPolicy = bufferingPolicy
        self.latestElement = latest
    }

    public var latest: Element? {
        lock.withLock { latestElement }
    }

    public func subscribe(replayingLatest: Bool = false) -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: bufferingPolicy)
        let initial: Element? = lock.withLock {
            continuations[id] = continuation
            return replayingLatest ? latestElement : nil
        }
        if let initial {
            continuation.yield(initial)
        }
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    public func yield(_ element: Element) {
        let targets = lock.withLock {
            latestElement = element
            return Array(continuations.values)
        }
        for continuation in targets {
            continuation.yield(element)
        }
    }

    public func finish() {
        let targets = lock.withLock {
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        for continuation in targets {
            continuation.finish()
        }
    }

    public var subscriberCount: Int {
        lock.withLock { continuations.count }
    }

    private func remove(_ id: UUID) {
        lock.withLock { _ = continuations.removeValue(forKey: id) }
    }
}
