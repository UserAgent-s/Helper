import Domain
import Foundation
import Network

public struct RemoteDisplayConfiguration: Sendable, Equatable {
    public var httpPort: UInt16
    public var webSocketPort: UInt16
    public var token: String
    public var pageHTML: String
    public var bonjourName: String?
    public var authTimeout: Duration

    public init(httpPort: UInt16 = 8765, webSocketPort: UInt16 = 8766, token: String, pageHTML: String, bonjourName: String? = nil, authTimeout: Duration = .seconds(5)) {
        self.httpPort = httpPort
        self.webSocketPort = webSocketPort
        self.token = token
        self.pageHTML = pageHTML
        self.bonjourName = bonjourName
        self.authTimeout = authTimeout
    }
}

public struct RemoteDisplayStatus: Sendable, Equatable {
    public var isRunning: Bool
    public var httpPort: UInt16?
    public var webSocketPort: UInt16?
    public var clientCount: Int
    public var lastError: String?

    public static let stopped = RemoteDisplayStatus(isRunning: false, httpPort: nil, webSocketPort: nil, clientCount: 0, lastError: nil)
}

public enum RemoteDisplayError: Error, Sendable, Equatable {
    case alreadyRunning
    case listenerFailed(String)
    case invalidPort(UInt16)
}

final class RemoteClient: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
    private let lock = NSLock()
    private var authenticated = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    var isAuthenticated: Bool {
        get { lock.withLock { authenticated } }
        set { lock.withLock { authenticated = newValue } }
    }
}

public actor RemoteDisplayServer {
    public static let bonjourServiceType = "_meetinghints._tcp"

    private let queue = DispatchQueue(label: "com.local.MeetingAssistant.remote-display")
    private var configuration: RemoteDisplayConfiguration?
    private var httpListener: NWListener?
    private var webSocketListener: NWListener?
    private var clients: [UUID: RemoteClient] = [:]
    private var authTimers: [UUID: Task<Void, Never>] = [:]
    private var status = RemoteDisplayStatus.stopped
    private let commandBroadcaster = EventBroadcaster<RemoteCommand>()
    private let statusBroadcaster = EventBroadcaster<RemoteDisplayStatus>(latest: .stopped)
    private var snapshotProvider: @Sendable () async -> [RemoteOutboundMessage] = { [] }

    public init() {}

    nonisolated public func commands() -> AsyncStream<RemoteCommand> {
        commandBroadcaster.subscribe()
    }

    nonisolated public func statusUpdates() -> AsyncStream<RemoteDisplayStatus> {
        statusBroadcaster.subscribe(replayingLatest: true)
    }

    public var currentStatus: RemoteDisplayStatus {
        status
    }

    public func setSnapshotProvider(_ provider: @escaping @Sendable () async -> [RemoteOutboundMessage]) {
        snapshotProvider = provider
    }

    public func start(_ configuration: RemoteDisplayConfiguration) async throws {
        guard httpListener == nil, webSocketListener == nil else { throw RemoteDisplayError.alreadyRunning }
        self.configuration = configuration
        do {
            let http = try makeListener(port: configuration.httpPort, webSocket: false, bonjourName: configuration.bonjourName)
            let socket = try makeListener(port: configuration.webSocketPort, webSocket: true, bonjourName: nil)
            httpListener = http
            webSocketListener = socket
            http.newConnectionHandler = { [weak self] connection in
                Task { await self?.acceptHTTP(connection) }
            }
            socket.newConnectionHandler = { [weak self] connection in
                Task { await self?.acceptWebSocket(connection) }
            }
            let httpPort = try await startListener(http)
            let socketPort = try await startListener(socket)
            status = RemoteDisplayStatus(isRunning: true, httpPort: httpPort, webSocketPort: socketPort, clientCount: 0, lastError: nil)
            publishStatus()
        } catch {
            let description = (error as? RemoteDisplayError).map { "\($0)" } ?? "\(error)"
            await stop()
            status.lastError = description
            publishStatus()
            throw error
        }
    }

    public func stop() async {
        for timer in authTimers.values { timer.cancel() }
        authTimers.removeAll()
        for client in clients.values { client.connection.cancel() }
        clients.removeAll()
        httpListener?.cancel()
        webSocketListener?.cancel()
        httpListener = nil
        webSocketListener = nil
        configuration = nil
        status = .stopped
        publishStatus()
    }

    public func broadcast(_ message: RemoteOutboundMessage) {
        let payload = RemoteMessageCodec.encode(message)
        for client in clients.values where client.isAuthenticated {
            send(payload, to: client)
        }
    }

    private func makeListener(port: UInt16, webSocket: Bool, bonjourName: String?) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if webSocket {
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            options.maximumMessageSize = 1_048_576
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        }
        let listener: NWListener
        if port == 0 {
            listener = try NWListener(using: parameters)
        } else {
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw RemoteDisplayError.invalidPort(port) }
            listener = try NWListener(using: parameters, on: endpointPort)
        }
        if let bonjourName {
            listener.service = NWListener.Service(name: bonjourName, type: Self.bonjourServiceType)
        }
        return listener
    }

    private func startListener(_ listener: NWListener) async throws -> UInt16 {
        let queue = self.queue
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumer = SingleResumeBox(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    resumer.resume(.success(listener.port?.rawValue ?? 0))
                case .failed(let error):
                    resumer.resume(.failure(RemoteDisplayError.listenerFailed(error.debugDescription)))
                    Task { await self?.recordFailure(error.debugDescription) }
                case .cancelled:
                    resumer.resume(.failure(RemoteDisplayError.listenerFailed("cancelled")))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func recordFailure(_ description: String) {
        status.lastError = description
        publishStatus()
    }

    private func acceptHTTP(_ connection: NWConnection) {
        guard let configuration else {
            connection.cancel()
            return
        }
        let page = configuration.pageHTML
        let socketPort = status.webSocketPort
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
            guard error == nil, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let response = RemoteHTTPResponder.respond(to: request, page: page, webSocketPort: socketPort)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func acceptWebSocket(_ connection: NWConnection) {
        let client = RemoteClient(connection: connection)
        clients[client.id] = client
        let clientID = client.id
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.remove(clientID) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNext(client)
        let timeout = configuration?.authTimeout ?? .seconds(5)
        authTimers[clientID] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.closeIfUnauthenticated(clientID)
        }
    }

    private func receiveNext(_ client: RemoteClient) {
        client.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let clientID = client.id
            if error != nil {
                Task { await self.remove(clientID) }
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            let opcode = metadata?.opcode
            Task { await self.handleMessage(data, opcode: opcode, from: client) }
        }
    }

    private func handleMessage(_ data: Data?, opcode: NWProtocolWebSocket.Opcode?, from client: RemoteClient) async {
        guard clients[client.id] != nil else { return }
        switch opcode {
        case .close?:
            remove(client.id)
            return
        case .text?, .binary?:
            if let data, let message = RemoteMessageCodec.decode(data) {
                let keepOpen = await process(message, from: client)
                guard keepOpen else { return }
            } else if !client.isAuthenticated {
                reject(client)
                return
            }
        default:
            break
        }
        receiveNext(client)
    }

    private func process(_ message: RemoteInboundMessage, from client: RemoteClient) async -> Bool {
        guard let configuration else { return false }
        if !client.isAuthenticated {
            guard case .auth(let token) = message, Self.constantTimeEquals(token, configuration.token) else {
                reject(client)
                return false
            }
            client.isAuthenticated = true
            authTimers[client.id]?.cancel()
            authTimers[client.id] = nil
            send(RemoteMessageCodec.encode(.hello), to: client)
            for snapshotMessage in await snapshotProvider() {
                send(RemoteMessageCodec.encode(snapshotMessage), to: client)
            }
            status.clientCount = authenticatedCount
            publishStatus()
            return true
        }
        switch message {
        case .auth:
            break
        case .ping:
            send(RemoteMessageCodec.encode(.pong), to: client)
        case .answerNow:
            commandBroadcaster.yield(.answerNow)
        case .expand(let hintID):
            commandBroadcaster.yield(.expand(hintID: hintID))
        case .resetContext:
            commandBroadcaster.yield(.resetContext)
        case .setMode(let mode):
            commandBroadcaster.yield(.setMode(mode))
        }
        return true
    }

    private func reject(_ client: RemoteClient) {
        let payload = RemoteMessageCodec.encode(.authFailed)
        let connection = client.connection
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "remote-display-reject", metadata: [metadata])
        connection.send(content: payload, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
        remove(client.id)
    }

    private func closeIfUnauthenticated(_ clientID: UUID) {
        guard let client = clients[clientID], !client.isAuthenticated else { return }
        client.connection.cancel()
        remove(clientID)
    }

    private func remove(_ clientID: UUID) {
        authTimers[clientID]?.cancel()
        authTimers[clientID] = nil
        guard let client = clients.removeValue(forKey: clientID) else { return }
        client.connection.cancel()
        let count = authenticatedCount
        if status.clientCount != count {
            status.clientCount = count
            publishStatus()
        }
    }

    private var authenticatedCount: Int {
        clients.values.filter(\.isAuthenticated).count
    }

    private func send(_ payload: Data, to client: RemoteClient) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "remote-display", metadata: [metadata])
        client.connection.send(content: payload, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func publishStatus() {
        statusBroadcaster.yield(status)
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count, !left.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

private final class SingleResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?

    init(_ continuation: CheckedContinuation<UInt16, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<UInt16, Error>) {
        let pending: CheckedContinuation<UInt16, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}
