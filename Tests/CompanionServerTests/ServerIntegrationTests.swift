import CompanionProtocol
import Foundation
import Testing
@testable import CompanionServer

actor FakeHubDelegate: CompanionHubDelegate {
    private(set) var performed: [ClientCommand.Action] = []
    var delay: Duration = .zero

    func setDelay(_ value: Duration) {
        delay = value
    }

    func snapshot() async -> StateSnapshot {
        StateSnapshot(mode: ModeInfo(mode: .answers, phase: .active), capabilities: ["answer_now"])
    }

    func perform(_ action: ClientCommand.Action, deviceId: String) async -> CompanionCommandOutcome {
        performed.append(action)
        if delay > .zero { try? await Task.sleep(for: delay) }
        return .ok
    }

    func exportDocument(sessionId: String) async -> CompanionExportOutcome {
        guard sessionId == "ses-ok" else { return .rejected(code: "unknown_session") }
        return .document(CompanionExportDocument(filename: "UserAgent057-2025-11-09-1500.md", markdown: "# Сессия\n"))
    }

    func history(_ action: ClientCommand.Action) async -> CompanionHistoryOutcome {
        switch action {
        case .historyList(let list):
            return .page(.init(q: list.q, items: [HistoryItem(sessionId: "ses-ok", kind: "assistant", title: "Звонок", startedAt: 1)]))
        case .historyGet(let get) where get.sessionId == "ses-ok":
            return .session(.init(sessionId: "ses-ok", kind: "assistant", title: nil, startedAt: 1, endedAt: nil, status: "completed", summary: nil, qa: [], expansions: [], transcript: [], moments: [], screens: [], truncated: false))
        case .historyGet(let get) where get.sessionId == "ses-huge":
            let line = HistoryLine(lineId: "u", speaker: .them, text: String(repeating: "x", count: 600_000))
            return .session(.init(sessionId: "ses-huge", kind: "assistant", title: nil, startedAt: 1, endedAt: nil, status: "completed", summary: nil, qa: [], expansions: [], transcript: [line, line], moments: [], screens: [], truncated: false))
        default:
            return .rejected(code: "unknown_session")
        }
    }
}

struct TimedOut: Error {}

func withTimeout<T: Sendable>(_ seconds: Double = 5, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { continuation in
        gate.install(continuation)
        let work = Task {
            do {
                gate.resume(.success(try await body()))
            } catch {
                gate.resume(.failure(error))
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            gate.resume(.failure(TimedOut()))
            work.cancel()
        }
    }
}

final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ result: Result<T, any Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<T, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

final class TestSocket: Sendable {
    let task: URLSessionWebSocketTask

    init(port: UInt16, headers: [String: String] = [:]) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
    }

    func send(_ command: ClientCommand) async throws {
        let data = try CompanionCodec.encode(command)
        try await task.send(.string(String(data: data, encoding: .utf8)!))
    }

    func sendRaw(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func next() async throws -> ServerEnvelope {
        let task = self.task
        return try await withTimeout {
            switch try await task.receive() {
            case .string(let text): return try CompanionCodec.decodeServer(Data(text.utf8))
            case .data(let data): return try CompanionCodec.decodeServer(data)
            @unknown default: throw TimedOut()
            }
        }
    }

    func next(where predicate: @Sendable (ServerEvent) -> Bool) async throws -> ServerEnvelope {
        while true {
            let envelope = try await next()
            if predicate(envelope.event) { return envelope }
        }
    }

    func closeCode() async throws -> Int {
        while true {
            do {
                _ = try await next()
            } catch is TimedOut {
                throw TimedOut()
            } catch {
                return task.closeCode.rawValue
            }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

struct ServerFixture {
    let transport: FlyingFoxCompanionTransport
    let hub: CompanionHub
    let pairing: PairingStore
    let delegate: FakeHubDelegate
    let port: UInt16

    static func start(preferredPort: UInt16 = 0, helloTimeout: Duration = .seconds(10), replayCapacity: Int = 2000) async throws -> ServerFixture {
        let pairing = PairingStore(storage: InMemoryPairedDeviceStore())
        let delegate = FakeHubDelegate()
        let hub = CompanionHub(pairing: pairing, delegate: delegate, serverVersion: "test", helloTimeout: helloTimeout, replayCapacity: replayCapacity)
        let transport = FlyingFoxCompanionTransport(localAddresses: { [] })
        let port = try await transport.start(
            configuration: CompanionServerConfiguration(preferredPort: preferredPort, bind: .loopback),
            hub: hub
        )
        return ServerFixture(transport: transport, hub: hub, pairing: pairing, delegate: delegate, port: port)
    }

    func token(_ name: String = "Test") async throws -> PairingGrant {
        try await pairing.redeem(code: await pairing.issueCode(.qr128).value, deviceName: name)
    }

    func connect(token: String, lastSeq: Int? = nil) async throws -> TestSocket {
        let socket = TestSocket(port: port)
        try await socket.send(ClientCommand(cmdId: "h-\(UUID().uuidString.prefix(8))", action: .hello(.init(token: token, lastSeq: lastSeq))))
        return socket
    }

    func authenticated(_ name: String = "Test") async throws -> TestSocket {
        let grant = try await token(name)
        let socket = try await connect(token: grant.deviceToken)
        _ = try await socket.next(where: { if case .stateSnapshot = $0 { true } else { false } })
        return socket
    }

    func http(_ path: String, headers: [String: String] = [:]) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (response as! HTTPURLResponse, data)
    }
}

@Suite(.serialized) struct ServerIntegrationTests {
    @Test func helloYieldsHelloOkThenSnapshot() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let grant = try await server.token()
        let socket = try await server.connect(token: grant.deviceToken)
        let first = try await socket.next()
        guard case .helloOK(let ok) = first.event else { Issue.record("expected hello.ok, got \(first.event)"); return }
        #expect(ok.deviceId == grant.deviceId)
        #expect(ok.replayed == false)
        let second = try await socket.next()
        guard case .stateSnapshot(let snapshot) = second.event else { Issue.record("expected snapshot"); return }
        #expect(snapshot.mode.mode == .answers)
        #expect(second.seq > first.seq)
        socket.close()
    }

    @Test func invalidTokenClosesWith4401() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let socket = try await server.connect(token: "not-a-token")
        let error = try await socket.next()
        guard case .error(let failure) = error.event else { Issue.record("expected error"); return }
        #expect(failure.code == "unauthorized")
        #expect(failure.fatal)
        #expect(try await socket.closeCode() == 4401)
    }

    @Test func commandBeforeHelloClosesWith4401() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let socket = TestSocket(port: server.port)
        try await socket.send(ClientCommand(cmdId: "c1", action: .answerNow))
        #expect(try await socket.closeCode() == 4401)
        #expect(await server.delegate.performed.isEmpty)
    }

    @Test func duplicateCmdIdFiresOnceAndAcksTwice() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let socket = try await server.authenticated()
        try await socket.send(ClientCommand(cmdId: "answer-1", action: .answerNow))
        try await socket.send(ClientCommand(cmdId: "answer-1", action: .answerNow))
        let first = try await socket.next(where: { if case .ack = $0 { true } else { false } })
        let second = try await socket.next(where: { if case .ack = $0 { true } else { false } })
        #expect(first.event == .ack(.init(cmdId: "answer-1", ok: true)))
        #expect(second.event == .ack(.init(cmdId: "answer-1", ok: true)))
        #expect(await server.delegate.performed == [.answerNow])
        socket.close()
    }

    @Test func duplicateCmdIdAcrossReconnectStillFiresOnce() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let grant = try await server.token()
        let first = try await server.connect(token: grant.deviceToken)
        _ = try await first.next(where: { if case .stateSnapshot = $0 { true } else { false } })
        try await first.send(ClientCommand(cmdId: "answer-x", action: .answerNow))
        _ = try await first.next(where: { if case .ack = $0 { true } else { false } })
        first.close()
        let second = try await server.connect(token: grant.deviceToken)
        _ = try await second.next(where: { if case .stateSnapshot = $0 { true } else { false } })
        try await second.send(ClientCommand(cmdId: "answer-x", action: .answerNow))
        _ = try await second.next(where: { if case .ack = $0 { true } else { false } })
        #expect(await server.delegate.performed == [.answerNow])
        second.close()
    }

    @Test func broadcastReachesTwoClientsAndThirdIsRejected() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let a = try await server.authenticated("A")
        let b = try await server.authenticated("B")
        await server.hub.publish(.notice(.init(code: "hello_world", severity: .info)))
        for socket in [a, b] {
            let envelope = try await socket.next(where: { if case .notice = $0 { true } else { false } })
            #expect(envelope.event == .notice(.init(code: "hello_world", severity: .info)))
        }
        let grant = try await server.token("C")
        let c = try await server.connect(token: grant.deviceToken)
        let rejection = try await c.next()
        #expect(rejection.event == .error(.init(code: "too_many_clients", fatal: true)))
        #expect(try await c.closeCode() == 4409)
        #expect(await server.hub.authenticatedDeviceIds.count == 2)
        a.close()
        b.close()
    }

    @Test func oversizedMessageClosesConnection() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let socket = try await server.authenticated()
        try await socket.sendRaw(String(repeating: "x", count: CompanionLimits.maxInboundFrameBytes + 1))
        #expect(try await socket.closeCode() == 1009)
    }

    @Test func malformedFrameBeforeHelloClosesWithProtocolError() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let socket = TestSocket(port: server.port)
        try await socket.sendRaw("{not json")
        #expect(try await socket.closeCode() == 1002)
    }

    @Test func helloTimeoutClosesSilentConnection() async throws {
        let server = try await ServerFixture.start(helloTimeout: .milliseconds(200))
        defer { Task { await server.transport.stop() } }
        let socket = TestSocket(port: server.port)
        #expect(try await socket.closeCode() == 4408)
    }

    @Test func revokeClosesOpenConnection() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let grant = try await server.token()
        let socket = try await server.connect(token: grant.deviceToken)
        _ = try await socket.next(where: { if case .stateSnapshot = $0 { true } else { false } })
        try await server.pairing.revoke(deviceId: grant.deviceId)
        let error = try await socket.next()
        #expect(error.event == .error(.init(code: "revoked", fatal: true)))
        #expect(try await socket.closeCode() == 4401)
    }

    @Test func pairOverWebSocketThenHello() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let code = await server.pairing.issueCode(.qr128)
        let socket = TestSocket(port: server.port)
        try await socket.send(ClientCommand(cmdId: "p1", action: .pair(.init(code: code.value, deviceName: "Browser"))))
        let paired = try await socket.next()
        guard case .pairOK(let ok) = paired.event else { Issue.record("expected pair.ok"); return }
        #expect(try await socket.next().event == .ack(.init(cmdId: "p1", ok: true)))
        try await socket.send(ClientCommand(cmdId: "h1", action: .hello(.init(token: ok.deviceToken))))
        guard case .helloOK = try await socket.next().event else { Issue.record("expected hello.ok"); return }
        socket.close()
    }

    @Test func reusedPairingCodeIsRejected() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let code = await server.pairing.issueCode(.qr128)
        _ = try await server.pairing.redeem(code: code.value, deviceName: "First")
        let socket = TestSocket(port: server.port)
        try await socket.send(ClientCommand(cmdId: "p1", action: .pair(.init(code: code.value, deviceName: "Second"))))
        #expect(try await socket.next().event == .ack(.init(cmdId: "p1", ok: false, code: "pair_invalid_code")))
        socket.close()
    }

    @Test func helloWithLastSeqReplaysMissedEvents() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let grant = try await server.token()
        let first = try await server.connect(token: grant.deviceToken)
        let snapshot = try await first.next(where: { if case .stateSnapshot = $0 { true } else { false } })
        first.close()
        try await waitFor { await server.hub.authenticatedDeviceIds.isEmpty }
        await server.hub.publish(.notice(.init(code: "missed_1", severity: .info)))
        await server.hub.publish(.notice(.init(code: "missed_2", severity: .warning)))
        let second = try await server.connect(token: grant.deviceToken, lastSeq: snapshot.seq)
        guard case .helloOK(let ok) = try await second.next().event else { Issue.record("expected hello.ok"); return }
        #expect(ok.replayed)
        #expect(try await second.next().event == .notice(.init(code: "missed_1", severity: .info)))
        #expect(try await second.next().event == .notice(.init(code: "missed_2", severity: .warning)))
        second.close()
    }

    @Test func staticRoutesCarrySecurityHeaders() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let (index, body) = try await server.http("/")
        #expect(index.statusCode == 200)
        #expect(index.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("default-src 'self'") == true)
        #expect(index.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(index.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
        #expect(String(decoding: body, as: UTF8.self).contains("app.js"))
        #expect(try await server.http("/app.js").0.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/javascript") == true)
        #expect(try await server.http("/app.css").0.statusCode == 200)
        for module in ["/protocol.js", "/store.js", "/ui.js"] {
            let (response, _) = try await server.http(module)
            #expect(response.statusCode == 200)
            #expect(response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/javascript") == true)
            #expect(response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("default-src 'self'") == true)
        }
        #expect(try await server.http("/index.html").0.statusCode == 200)
        #expect(try await server.http("/missing.js").0.statusCode == 404)
        #expect(try await server.http("/../Package.swift").0.statusCode == 404)
        #expect(try await server.http("/healthz").0.statusCode == 200)
        #expect(try await server.http("/missing").0.statusCode == 404)
    }

    @Test func foreignOriginAndRebindedHostAreForbidden() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        #expect(try await server.http("/healthz", headers: ["Origin": "http://evil.example"]).0.statusCode == 403)
        #expect(try await server.http("/healthz", headers: ["Host": "evil.example:\(server.port)"]).0.statusCode == 403)
        let socket = TestSocket(port: server.port, headers: ["Origin": "http://evil.example"])
        await #expect(throws: (any Error).self) { _ = try await socket.next() }
    }

    @Test func stoppedServerReleasesPort() async throws {
        let server = try await ServerFixture.start()
        let socket = try await server.authenticated()
        await server.transport.stop()
        #expect(await server.transport.isRunning == false)
        #expect(try await socket.closeCode() == 1001)
        await #expect(throws: (any Error).self) { _ = try await server.http("/healthz") }
        let again = try await ServerFixture.start(preferredPort: server.port)
        #expect(again.port == server.port)
        await again.transport.stop()
    }

    @Test func busyPreferredPortFallsBackToFreePort() async throws {
        let first = try await ServerFixture.start()
        defer { Task { await first.transport.stop() } }
        let second = try await ServerFixture.start(preferredPort: first.port)
        defer { Task { await second.transport.stop() } }
        #expect(second.port != first.port)
        #expect(try await second.http("/healthz").0.statusCode == 200)
    }
}

func waitFor(timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TimedOut()
}
