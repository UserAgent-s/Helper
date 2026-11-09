import CompanionProtocol
import FlyingFox
import FlyingSocks
import Foundation

public actor FlyingFoxCompanionTransport: CompanionTransport {
    private var server: HTTPServer?
    private var runTask: Task<Void, any Error>?
    private var hub: CompanionHub?
    private let localAddresses: @Sendable () -> [String]

    public init(localAddresses: @escaping @Sendable () -> [String] = LocalInterfaceAddresses.current) {
        self.localAddresses = localAddresses
    }

    public var isRunning: Bool {
        server != nil
    }

    public func start(configuration: CompanionServerConfiguration, hub: CompanionHub) async throws -> UInt16 {
        await stop()
        await hub.activate()
        self.hub = hub
        var lastError: (any Error)?
        for candidate in configuration.preferredPort == 0 ? [UInt16(0)] : [configuration.preferredPort, 0] {
            do {
                return try await listen(on: candidate, configuration: configuration, hub: hub)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? SocketError.unsupportedAddress
    }

    public func stop() async {
        await hub?.closeAll()
        hub = nil
        guard let server else { return }
        self.server = nil
        await server.stop(timeout: 1)
        runTask?.cancel()
        _ = await runTask?.result
        runTask = nil
    }

    private func listen(on port: UInt16, configuration: CompanionServerConfiguration, hub: CompanionHub) async throws -> UInt16 {
        let router = CompanionHTTPHandler(hub: hub, configuration: configuration, localAddresses: localAddresses)
        let address: any SocketAddress = switch configuration.bind {
        case .anyInterface: sockaddr_in6.inet6(port: port)
        case .loopback: try sockaddr_in.inet(ip4: "127.0.0.1", port: port)
        }
        let server = HTTPServer(config: HTTPServer.Configuration(address: address, logger: .disabled), handler: router)
        let failure = LockedValue<(any Error)?>(nil)
        let task = Task {
            do {
                try await server.run()
            } catch {
                failure.set(error)
                throw error
            }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await server.isListening) {
            if let error = failure.get() {
                throw error
            }
            guard ContinuousClock.now < deadline else {
                task.cancel()
                await server.stop()
                throw SocketError.unsupportedAddress
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let bound = await server.listeningAddress else {
            task.cancel()
            await server.stop()
            throw SocketError.unsupportedAddress
        }
        let boundPort: UInt16
        switch bound {
        case .ip4(_, let value), .ip6(_, let value): boundPort = value
        default: boundPort = port
        }
        router.boundPort.set(boundPort)
        self.server = server
        runTask = task
        return boundPort
    }
}

final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }

    func update<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}

struct CompanionHTTPHandler: HTTPHandler {
    static let securityHeaders: [HTTPHeader: String] = [
        HTTPHeader("Content-Security-Policy"): "default-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        .cacheControl: "no-store",
        HTTPHeader("X-Content-Type-Options"): "nosniff",
        HTTPHeader("Referrer-Policy"): "no-referrer",
        HTTPHeader("X-Frame-Options"): "DENY",
    ]

    let hub: CompanionHub
    let configuration: CompanionServerConfiguration
    let localAddresses: @Sendable () -> [String]
    let boundPort = LockedValue<UInt16>(0)

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let remote = Self.remoteIP(request) else {
            return Self.response(.forbidden, body: "forbidden")
        }
        guard await hub.admissionDelay(for: remote) == 0 else {
            return Self.response(.tooManyRequests, body: "throttled")
        }
        let requestGuard = RequestGuard(port: Int(boundPort.get()))
        let addresses = localAddresses() + ["127.0.0.1", "::1"]
        if let rejection = requestGuard.evaluate(
            remoteAddress: remote,
            host: request.headers[.host],
            origin: request.headers[HTTPHeader("Origin")],
            serverAddresses: addresses
        ) {
            await hub.recordRejectedRequest(from: remote)
            return Self.response(.forbidden, body: rejection.rawValue)
        }
        guard request.method == .GET else {
            return Self.response(.methodNotAllowed, body: "method not allowed")
        }
        switch request.path {
        case "/ws":
            let handler = CompanionWSHandler(hub: hub, remoteAddress: remote, configuration: configuration)
            var response = try await WebSocketHTTPHandler(handler: handler).handleRequest(request)
            for (header, value) in Self.securityHeaders { response.headers[header] = value }
            return response
        case "/healthz":
            return Self.response(.ok, body: "ok")
        case "/", "/index.html":
            return Self.asset("index", "html", contentType: "text/html; charset=utf-8")
        case "/app.js":
            return Self.asset("app", "js", contentType: "text/javascript; charset=utf-8")
        case "/app.css":
            return Self.asset("app", "css", contentType: "text/css; charset=utf-8")
        default:
            return Self.response(.notFound, body: "not found")
        }
    }

    static func remoteIP(_ request: HTTPRequest) -> String? {
        switch request.remoteAddress {
        case .ip4(let ip, _), .ip6(let ip, _): ip
        default: nil
        }
    }

    static func asset(_ name: String, _ ext: String, contentType: String) -> HTTPResponse {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Web"),
              let data = try? Data(contentsOf: url)
        else { return response(.notFound, body: "not found") }
        return response(.ok, data: data, contentType: contentType)
    }

    static func response(_ status: HTTPStatusCode, body: String) -> HTTPResponse {
        response(status, data: Data(body.utf8), contentType: "text/plain; charset=utf-8")
    }

    static func response(_ status: HTTPStatusCode, data: Data, contentType: String) -> HTTPResponse {
        var headers = HTTPHeaders(securityHeaders)
        headers[.contentType] = contentType
        return HTTPResponse(statusCode: status, headers: headers, body: data)
    }
}

struct CompanionWSHandler: WSHandler {
    let hub: CompanionHub
    let remoteAddress: String
    let configuration: CompanionServerConfiguration

    func makeFrames(for client: AsyncThrowingStream<WSFrame, any Error>) async throws -> AsyncStream<WSFrame> {
        let (frames, continuation) = AsyncStream<WSFrame>.makeStream()
        let outbound = CompanionOutbound(
            send: { text in
                continuation.yield(WSFrame(fin: true, opcode: .text, mask: nil, payload: Data(text.utf8)))
            },
            close: { code, reason in
                continuation.yield(.close(code: WSCloseCode(code, reason: reason)))
                continuation.finish()
            }
        )
        guard let id = await hub.open(outbound, remoteAddress: remoteAddress) else {
            outbound.close(CompanionCloseCode.tooManyClients, "too_many_pending")
            return frames
        }
        let hub = self.hub
        let limit = configuration.maxInboundMessageBytes
        let interval = configuration.pingInterval
        let lastHeard = LockedValue(ContinuousClock.now)
        let reader = Task {
            var partial: Data?
            do {
                for try await frame in client {
                    lastHeard.set(.now)
                    switch frame.opcode {
                    case .text:
                        guard partial == nil else { throw CompanionFrameError.protocolViolation }
                        guard frame.payload.count <= limit else { throw CompanionFrameError.tooBig }
                        if frame.fin {
                            await Self.deliver(frame.payload, id: id, hub: hub)
                        } else {
                            partial = frame.payload
                        }
                    case .continuation:
                        guard var buffer = partial else { throw CompanionFrameError.protocolViolation }
                        buffer.append(frame.payload)
                        guard buffer.count <= limit else { throw CompanionFrameError.tooBig }
                        if frame.fin {
                            partial = nil
                            await Self.deliver(buffer, id: id, hub: hub)
                        } else {
                            partial = buffer
                        }
                    case .binary:
                        throw CompanionFrameError.binary
                    case .ping:
                        guard frame.payload.count <= 125 else { throw CompanionFrameError.protocolViolation }
                        continuation.yield(WSFrame(fin: true, opcode: .pong, mask: nil, payload: frame.payload))
                    case .pong:
                        break
                    case .close:
                        continuation.yield(.close(code: .normalClosure))
                        continuation.finish()
                        await hub.closed(id)
                        return
                    default:
                        throw CompanionFrameError.protocolViolation
                    }
                }
            } catch CompanionFrameError.tooBig {
                await hub.closed(id)
                outbound.close(CompanionCloseCode.messageTooBig, "frame_too_large")
                return
            } catch CompanionFrameError.binary {
                await hub.closed(id)
                outbound.close(CompanionCloseCode.unsupportedData, "binary_not_supported")
                return
            } catch {
                await hub.closed(id)
                outbound.close(CompanionCloseCode.protocolError, "protocol_error")
                return
            }
            await hub.closed(id)
            continuation.finish()
        }
        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                if ContinuousClock.now - lastHeard.get() > interval * 3 {
                    await hub.closed(id)
                    outbound.close(CompanionCloseCode.goingAway, "ping_timeout")
                    return
                }
                continuation.yield(WSFrame(fin: true, opcode: .ping, mask: nil, payload: Data()))
            }
        }
        continuation.onTermination = { _ in
            reader.cancel()
            pinger.cancel()
            Task { await hub.closed(id) }
        }
        return frames
    }

    private static func deliver(_ payload: Data, id: UUID, hub: CompanionHub) async {
        guard let text = String(data: payload, encoding: .utf8) else {
            await hub.receive("\u{FFFD}", from: id)
            return
        }
        await hub.receive(text, from: id)
    }
}

enum CompanionFrameError: Error {
    case tooBig
    case binary
    case protocolViolation
}
