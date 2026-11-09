import Foundation
@testable import RealtimeClient

struct TransportTestError: Error, Sendable, Equatable {
    let message: String
}

final class FakeRealtimeWebSocketTransport: RealtimeWebSocketTransport, @unchecked Sendable {
    private let stateLock = NSLock()
    private var _connectCallCount = 0
    private var _closeCallCount = 0
    private var _lastBearerToken: String?
    private var _sentEvents: [RealtimeClientEvent] = []
    private var currentContinuation: AsyncStream<RealtimeTransportEvent>.Continuation?
    var connectError: TransportTestError?

    private func withLockedState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    func connect(url: URL, auth: AuthStrategy) async throws {
        withLockedState {
            _connectCallCount += 1
            if case .bearer(let token) = auth { _lastBearerToken = token }
        }
        if let connectError { throw connectError }
    }

    func send(_ event: RealtimeClientEvent) async throws {
        withLockedState { _sentEvents.append(event) }
    }

    func events() -> AsyncStream<RealtimeTransportEvent> {
        let (stream, cont) = AsyncStream<RealtimeTransportEvent>.makeStream()
        withLockedState { currentContinuation = cont }
        return stream
    }

    func close() async {
        withLockedState { _closeCallCount += 1 }
    }

    func emit(_ event: RealtimeServerEvent) {
        withLockedState { currentContinuation }?.yield(.serverEvent(event))
    }

    func emitClosed(reason: String?) {
        withLockedState { currentContinuation }?.yield(.closed(reason: reason))
    }

    var connectCallCount: Int { withLockedState { _connectCallCount } }
    var closeCallCount: Int { withLockedState { _closeCallCount } }
    var lastBearerToken: String? { withLockedState { _lastBearerToken } }
    var sentEvents: [RealtimeClientEvent] { withLockedState { _sentEvents } }
    var responseCreateCount: Int {
        sentEvents.filter { if case .responseCreate = $0 { true } else { false } }.count
    }
}
