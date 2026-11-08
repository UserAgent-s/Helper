import Foundation

public enum RealtimeTransportEvent: Sendable {
    case serverEvent(RealtimeServerEvent)
    case closed(reason: String?)
    case failed(String)
}

public enum AuthStrategy: Sendable, Equatable {
    case bearer(String)
    case header(name: String, value: String)

    func apply(to request: inout URLRequest) {
        switch self {
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .header(let name, let value):
            request.setValue(value, forHTTPHeaderField: name)
        }
    }
}

public protocol RealtimeWebSocketTransport: Sendable {
    func connect(url: URL, auth: AuthStrategy) async throws
    func send(_ event: RealtimeClientEvent) async throws
    func events() -> AsyncStream<RealtimeTransportEvent>
    func close() async
}

public final class URLSessionRealtimeWebSocketTransport: NSObject, RealtimeWebSocketTransport, @unchecked Sendable {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var generation = 0
    private let stateLock = NSLock()
    private var continuation: AsyncStream<RealtimeTransportEvent>.Continuation?
    private let logger: @Sendable (String) -> Void

    public init(logger: @escaping @Sendable (String) -> Void = { _ in }) {
        self.logger = logger
    }

    private func withLockedState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    public func connect(url: URL, auth: AuthStrategy) async throws {
        var request = URLRequest(url: url)
        auth.apply(to: &request)

        let urlSession = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: nil)
        let webSocketTask = urlSession.webSocketTask(with: request)

        let myGeneration = withLockedState {
            generation += 1
            session = urlSession
            task = webSocketTask
            return generation
        }

        webSocketTask.resume()
        receiveLoop(on: webSocketTask, generation: myGeneration)
    }

    public func events() -> AsyncStream<RealtimeTransportEvent> {
        let (stream, cont) = AsyncStream<RealtimeTransportEvent>.makeStream()
        withLockedState { continuation = cont }
        return stream
    }

    public func send(_ event: RealtimeClientEvent) async throws {
        let data = try JSONEncoder().encode(event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeTransportError.encodingFailed
        }
        let activeTask = withLockedState { task }
        guard let activeTask else { throw RealtimeTransportError.notConnected }
        try await activeTask.send(.string(text))
    }

    public func close() async {
        let (activeTask, activeSession, cont) = withLockedState { () -> (URLSessionWebSocketTask?, URLSession?, AsyncStream<RealtimeTransportEvent>.Continuation?) in
            generation += 1
            let result = (task, session, continuation)
            task = nil
            session = nil
            continuation = nil
            return result
        }
        activeTask?.cancel(with: .goingAway, reason: nil)
        activeSession?.invalidateAndCancel()
        cont?.finish()
    }

    private func receiveLoop(on task: URLSessionWebSocketTask, generation myGeneration: Int) {
        Task { [weak self] in
            guard let self else { return }
            while true {
                do {
                    let message = try await task.receive()
                    guard self.withLockedState({ self.generation }) == myGeneration else { return }
                    switch message {
                    case .string(let text):
                        self.handleIncoming(text, generation: myGeneration)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleIncoming(text, generation: myGeneration)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    guard self.withLockedState({ self.generation }) == myGeneration else { return }
                    self.logger("realtime transport receive loop ended: \(type(of: error))")
                    let cont = self.withLockedState { self.continuation }
                    cont?.yield(.closed(reason: "\(type(of: error))"))
                    return
                }
            }
        }
    }

    private func handleIncoming(_ text: String, generation myGeneration: Int) {
        guard let data = text.data(using: .utf8) else { return }
        let event = RealtimeServerEventDecoder.decode(data)
        let cont = withLockedState { self.generation == myGeneration ? continuation : nil }
        cont?.yield(.serverEvent(event))
    }
}

public enum RealtimeTransportError: Error, Sendable, Equatable {
    case notConnected
    case encodingFailed
}
