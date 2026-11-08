import Foundation
import os

public enum BroadcastBufferPolicy: Sendable, Equatable {
    case unbounded
    case bufferingNewest(Int)
    case bufferingOldest(Int)
}

public final class AsyncBroadcaster<Element: Sendable>: Sendable {
    private struct Subscriber {
        let name: String
        let continuation: AsyncStream<Element>.Continuation
        var dropped: Int
    }

    private struct State {
        var subscribers: [UUID: Subscriber] = [:]
        var droppedByName: [String: Int] = [:]
        var latest: Element?
        var finished = false
    }

    private let replayLatest: Bool
    private let state: OSAllocatedUnfairLock<State>

    public init(replayLatest: Bool = false, initial: Element? = nil) {
        self.replayLatest = replayLatest
        self.state = OSAllocatedUnfairLock(initialState: State(latest: initial))
    }

    public func subscribe(_ name: String = "anonymous", policy: BroadcastBufferPolicy = .unbounded) -> AsyncStream<Element> {
        let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy
        switch policy {
        case .unbounded: bufferingPolicy = .unbounded
        case .bufferingNewest(let n): bufferingPolicy = .bufferingNewest(max(1, n))
        case .bufferingOldest(let n): bufferingPolicy = .bufferingOldest(max(1, n))
        }
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: bufferingPolicy)
        let id = UUID()
        let snapshot: (finished: Bool, replay: Element?) = state.withLock { s in
            if s.finished { return (true, nil) }
            s.subscribers[id] = Subscriber(name: name, continuation: continuation, dropped: 0)
            return (false, replayLatest ? s.latest : nil)
        }
        if snapshot.finished {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        if let replay = snapshot.replay {
            continuation.yield(replay)
        }
        return stream
    }

    public func yield(_ element: Element) {
        let targets: [(UUID, AsyncStream<Element>.Continuation)] = state.withLock { s in
            guard !s.finished else { return [] }
            s.latest = element
            return s.subscribers.map { ($0.key, $0.value.continuation) }
        }
        var droppedIDs: [UUID] = []
        for (id, continuation) in targets {
            if case .dropped = continuation.yield(element) {
                droppedIDs.append(id)
            }
        }
        guard !droppedIDs.isEmpty else { return }
        let dropped = droppedIDs
        state.withLock { s in
            for id in dropped {
                guard var sub = s.subscribers[id] else { continue }
                sub.dropped += 1
                s.subscribers[id] = sub
                s.droppedByName[sub.name, default: 0] += 1
            }
        }
    }

    public func finish() {
        let targets: [AsyncStream<Element>.Continuation] = state.withLock { s in
            guard !s.finished else { return [] }
            s.finished = true
            let all = s.subscribers.values.map(\.continuation)
            s.subscribers.removeAll()
            return all
        }
        for continuation in targets {
            continuation.finish()
        }
    }

    public func droppedCount(for name: String) -> Int {
        state.withLock { $0.droppedByName[name] ?? 0 }
    }

    public var subscriberCount: Int {
        state.withLock { $0.subscribers.count }
    }

    public var latest: Element? {
        state.withLock { $0.latest }
    }

    private func remove(_ id: UUID) {
        state.withLock { s in
            _ = s.subscribers.removeValue(forKey: id)
        }
    }
}
