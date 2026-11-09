import Foundation

extension ServerEvent {
    public var isReplayable: Bool {
        switch self {
        case .modeChanged, .notice, .transcriptDelta, .answerStarted, .answerDelta, .answerReplace, .answerDone,
             .sessionStarted, .sessionStopped, .bookmarkAdded, .bookmarkRemoved, .deepStarted, .deepDelta, .deepDone, .screenCaptured:
            true
        case .helloOK, .pairOK, .stateSnapshot, .level, .exportReady, .historyPage, .historySession, .ack, .error, .pong, .unknown:
            false
        }
    }
}

public struct ReplayBuffer: Sendable {
    public let capacity: Int
    public private(set) var latestSeq = 0
    private var evictedThroughSeq = 0
    private var storage: [ServerEnvelope] = []
    private var head = 0

    public init(capacity: Int = 2000) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }

    public mutating func append(_ envelope: ServerEnvelope) {
        guard envelope.seq > latestSeq else { return }
        latestSeq = envelope.seq
        guard envelope.event.isReplayable else { return }
        if storage.count < capacity {
            storage.append(envelope)
            return
        }
        evictedThroughSeq = storage[head].seq
        storage[head] = envelope
        head = (head + 1) % capacity
    }

    public func events(after lastSeq: Int) -> [ServerEnvelope]? {
        guard lastSeq >= 0, lastSeq <= latestSeq, lastSeq >= evictedThroughSeq else { return nil }
        guard lastSeq < latestSeq else { return [] }
        return ordered.filter { $0.seq > lastSeq }
    }

    public mutating func removeAll() {
        evictedThroughSeq = latestSeq
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    private var ordered: [ServerEnvelope] {
        Array(storage[head...] + storage[..<head])
    }
}
