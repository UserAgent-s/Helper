import CompanionProtocol
import Foundation

public actor CompanionHub {
    private struct Client {
        let outbound: CompanionOutbound
        let remoteAddress: String
        var deviceId: String?
        var helloTimer: Task<Void, Never>?
    }

    public static let maxAuthenticatedClients = 2
    public static let maxPendingClients = 8
    public static let ackCacheSize = 512

    private let pairing: PairingStore
    private let delegate: any CompanionHubDelegate
    private let serverVersion: String
    private let helloTimeout: Duration
    private let now: @Sendable () -> Date

    private var clients: [UUID: Client] = [:]
    private var seq = 0
    private var replay: ReplayBuffer
    private var throttle = FailureThrottle()
    private var acks: [String: Task<ServerEvent.Ack, Never>] = [:]
    private var ackOrder: [String] = []
    private var revocationTask: Task<Void, Never>?
    private var exportTickets: CompanionExportTickets
    private(set) var performedCommandCount = 0

    public init(
        pairing: PairingStore,
        delegate: any CompanionHubDelegate,
        serverVersion: String,
        helloTimeout: Duration = .seconds(10),
        replayCapacity: Int = 2000,
        exportTickets: CompanionExportTickets = CompanionExportTickets(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.exportTickets = exportTickets
        self.replay = ReplayBuffer(capacity: replayCapacity)
        self.pairing = pairing
        self.delegate = delegate
        self.serverVersion = serverVersion
        self.helloTimeout = helloTimeout
        self.now = now
    }

    public var authenticatedDeviceIds: [String] {
        clients.values.compactMap(\.deviceId).sorted()
    }

    public var connectionCount: Int {
        clients.count
    }

    public var latestSeq: Int {
        seq
    }

    public func activate() {
        guard revocationTask == nil else { return }
        let revocations = pairing.revocations
        revocationTask = Task { [weak self] in
            for await revocation in revocations {
                await self?.apply(revocation)
            }
        }
    }

    public func admissionDelay(for remoteAddress: String) -> TimeInterval {
        throttle.retryDelay(for: remoteAddress, now: now())
    }

    public func recordRejectedRequest(from remoteAddress: String) {
        throttle.recordFailure(for: remoteAddress, now: now())
    }

    public func open(_ outbound: CompanionOutbound, remoteAddress: String) -> UUID? {
        activate()
        let pending = clients.values.filter { $0.deviceId == nil }.count
        guard pending < Self.maxPendingClients else { return nil }
        let id = UUID()
        let timeout = helloTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.helloTimedOut(id)
        }
        clients[id] = Client(outbound: outbound, remoteAddress: remoteAddress, helloTimer: timer)
        return id
    }

    public func closed(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.helloTimer?.cancel()
    }

    public func closeAll(code: UInt16 = CompanionCloseCode.goingAway, reason: String = "server stopping") {
        for id in Array(clients.keys) {
            disconnect(id, code: code, reason: reason)
        }
    }

    public func publish(_ event: ServerEvent, sid: String? = nil) {
        guard let envelope = makeEnvelope(event, sid: sid), let text = encode(envelope) else { return }
        for client in clients.values where client.deviceId != nil {
            client.outbound.send(text)
        }
    }

    public func receive(_ text: String, from id: UUID) async {
        guard clients[id] != nil else { return }
        let command: ClientCommand
        do {
            command = try CompanionCodec.decodeCommand(text)
        } catch let error as CompanionProtocolError {
            reject(id, error)
            return
        } catch {
            reject(id, .malformed("decode"))
            return
        }

        switch command.action {
        case .hello(let hello):
            await handleHello(hello, from: id)
        case .pair(let pair):
            await handlePair(pair, cmdId: command.cmdId, from: id)
        case .ping(let ping):
            send(.pong(.init(nonce: ping.nonce)), to: id)
        case .unknown:
            send(.ack(.init(cmdId: command.cmdId, ok: false, code: "unknown_command")), to: id)
        case .exportRequest(let request):
            guard let deviceId = clients[id]?.deviceId else {
                fail(id, code: "unauthorized", closeCode: CompanionCloseCode.unauthorized)
                return
            }
            await handleExport(request, cmdId: command.cmdId, deviceId: deviceId, from: id)
        case .historyList, .historyGet:
            guard let deviceId = clients[id]?.deviceId else {
                fail(id, code: "unauthorized", closeCode: CompanionCloseCode.unauthorized)
                return
            }
            await handleHistory(command.action, cmdId: command.cmdId, deviceId: deviceId, from: id)
        default:
            guard let deviceId = clients[id]?.deviceId else {
                fail(id, code: "unauthorized", closeCode: CompanionCloseCode.unauthorized)
                return
            }
            let ack = await perform(command, deviceId: deviceId)
            send(.ack(ack), to: id)
        }
    }

    private func handleHello(_ hello: ClientCommand.Hello, from id: UUID) async {
        guard let client = clients[id] else { return }
        guard client.deviceId == nil else {
            send(.error(.init(code: "already_authenticated", fatal: false)), to: id)
            return
        }
        guard throttle.retryDelay(for: client.remoteAddress, now: now()) == 0 else {
            fail(id, code: "throttled", closeCode: CompanionCloseCode.throttled)
            return
        }
        let device: PairedDevice?
        do {
            device = try await pairing.authenticate(token: hello.token)
        } catch {
            fail(id, code: "internal_error", closeCode: CompanionCloseCode.goingAway)
            return
        }
        guard clients[id] != nil else { return }
        guard let device else {
            throttle.recordFailure(for: client.remoteAddress, now: now())
            fail(id, code: "unauthorized", closeCode: CompanionCloseCode.unauthorized)
            return
        }
        throttle.recordSuccess(for: client.remoteAddress)
        let authenticated = clients.values.filter { $0.deviceId != nil }.count
        guard authenticated < Self.maxAuthenticatedClients else {
            fail(id, code: "too_many_clients", closeCode: CompanionCloseCode.tooManyClients)
            return
        }
        clients[id]?.deviceId = device.deviceId
        clients[id]?.helloTimer?.cancel()
        clients[id]?.helloTimer = nil

        let missed = hello.lastSeq.flatMap { replay.events(after: $0) }
        send(.helloOK(.init(deviceId: device.deviceId, serverVersion: serverVersion, replayed: missed != nil)), to: id)
        if let missed {
            for envelope in missed {
                if let text = encode(envelope) { clients[id]?.outbound.send(text) }
            }
        } else {
            let snapshot = await delegate.snapshot()
            send(.stateSnapshot(snapshot), to: id)
        }
    }

    private func handlePair(_ pair: ClientCommand.Pair, cmdId: String, from id: UUID) async {
        guard let client = clients[id] else { return }
        guard client.deviceId == nil else {
            send(.ack(.init(cmdId: cmdId, ok: false, code: "already_authenticated")), to: id)
            return
        }
        guard throttle.retryDelay(for: client.remoteAddress, now: now()) == 0 else {
            fail(id, code: "throttled", closeCode: CompanionCloseCode.throttled)
            return
        }
        do {
            let grant = try await pairing.redeem(code: pair.code, deviceName: pair.deviceName)
            send(.pairOK(.init(deviceId: grant.deviceId, deviceToken: grant.deviceToken)), to: id)
            send(.ack(.init(cmdId: cmdId, ok: true)), to: id)
        } catch let error as PairingError {
            throttle.recordFailure(for: client.remoteAddress, now: now())
            send(.ack(.init(cmdId: cmdId, ok: false, code: error.code)), to: id)
        } catch {
            send(.ack(.init(cmdId: cmdId, ok: false, code: "internal_error")), to: id)
        }
    }

    public func redeemExport(sessionId: String, ticket: String) -> CompanionExportDocument? {
        exportTickets.redeem(sessionId: sessionId, ticket: ticket, now: now())
    }

    public var outstandingExportTickets: Int {
        exportTickets.count
    }

    private func handleExport(_ request: ClientCommand.ExportRequest, cmdId: String, deviceId: String, from id: UUID) async {
        performedCommandCount += 1
        switch await delegate.exportDocument(sessionId: request.sessionId) {
        case .rejected(let code):
            send(.ack(.init(cmdId: cmdId, ok: false, code: code)), to: id)
        case .document(let document):
            guard clients[id]?.deviceId == deviceId else { return }
            let issued = exportTickets.issue(sessionId: request.sessionId, deviceId: deviceId, document: document, now: now())
            let ready = ServerEvent.ExportReady(
                sessionId: request.sessionId,
                url: "/export/\(request.sessionId).md?t=\(issued.ticket)",
                filename: document.filename,
                expiresAt: Int64((issued.expiresAt.timeIntervalSince1970 * 1000).rounded())
            )
            send(.exportReady(ready), to: id)
            send(.ack(.init(cmdId: cmdId, ok: true)), to: id)
        }
    }

    private func handleHistory(_ action: ClientCommand.Action, cmdId: String, deviceId: String, from id: UUID) async {
        performedCommandCount += 1
        let outcome = await delegate.history(action)
        guard clients[id]?.deviceId == deviceId else { return }
        switch outcome {
        case .rejected(let code):
            send(.ack(.init(cmdId: cmdId, ok: false, code: code)), to: id)
        case .page(let page):
            let delivered = send(.historyPage(page), to: id)
            send(.ack(.init(cmdId: cmdId, ok: delivered, code: delivered ? nil : "history_too_large")), to: id)
        case .session(let session):
            let delivered = send(.historySession(session), to: id)
            send(.ack(.init(cmdId: cmdId, ok: delivered, code: delivered ? nil : "history_too_large")), to: id)
        }
    }

    private func perform(_ command: ClientCommand, deviceId: String) async -> ServerEvent.Ack {
        let key = deviceId + "\u{1F}" + command.cmdId
        if let existing = acks[key] {
            return await existing.value
        }
        let delegate = self.delegate
        let cmdId = command.cmdId
        let action = command.action
        performedCommandCount += 1
        let task = Task<ServerEvent.Ack, Never> {
            switch await delegate.perform(action, deviceId: deviceId) {
            case .ok: ServerEvent.Ack(cmdId: cmdId, ok: true)
            case .rejected(let code, let message): ServerEvent.Ack(cmdId: cmdId, ok: false, code: code, message: message)
            }
        }
        acks[key] = task
        ackOrder.append(key)
        while ackOrder.count > Self.ackCacheSize {
            acks[ackOrder.removeFirst()] = nil
        }
        return await task.value
    }

    private func apply(_ revocation: PairingRevocation) {
        switch revocation {
        case .device(let deviceId): exportTickets.revoke(deviceId: deviceId)
        case .all: exportTickets.revoke(deviceId: nil)
        }
        for (id, client) in clients {
            guard let deviceId = client.deviceId else { continue }
            if case .device(let revoked) = revocation, revoked != deviceId { continue }
            fail(id, code: "revoked", closeCode: CompanionCloseCode.unauthorized)
        }
    }

    private func helloTimedOut(_ id: UUID) {
        guard let client = clients[id], client.deviceId == nil else { return }
        fail(id, code: "hello_timeout", closeCode: CompanionCloseCode.helloTimeout)
    }

    private func reject(_ id: UUID, _ error: CompanionProtocolError) {
        switch error {
        case .frameTooLarge:
            fail(id, code: error.code, closeCode: CompanionCloseCode.messageTooBig)
        case .unsupportedVersion:
            fail(id, code: error.code, closeCode: CompanionCloseCode.unsupportedVersion)
        default:
            if clients[id]?.deviceId == nil {
                fail(id, code: error.code, closeCode: CompanionCloseCode.protocolError)
            } else {
                send(.error(.init(code: error.code, fatal: false)), to: id)
            }
        }
    }

    private func fail(_ id: UUID, code: String, closeCode: UInt16) {
        send(.error(.init(code: code, fatal: true)), to: id)
        disconnect(id, code: closeCode, reason: code)
    }

    private func disconnect(_ id: UUID, code: UInt16, reason: String) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.helloTimer?.cancel()
        client.outbound.close(code, reason)
    }

    @discardableResult
    private func send(_ event: ServerEvent, to id: UUID) -> Bool {
        guard let client = clients[id], let envelope = makeEnvelope(event, sid: nil), let text = encode(envelope) else { return false }
        client.outbound.send(text)
        return true
    }

    private func makeEnvelope(_ event: ServerEvent, sid: String?) -> ServerEnvelope? {
        seq += 1
        let envelope = ServerEnvelope(seq: seq, ts: Int64((now().timeIntervalSince1970 * 1000).rounded()), sid: sid, event: event)
        replay.append(envelope)
        return envelope
    }

    private func encode(_ envelope: ServerEnvelope) -> String? {
        guard let data = try? CompanionCodec.encode(envelope) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
