import Domain
import Foundation
import Testing
@testable import RemoteDisplay

private let testPage = "<!doctype html><html><body data-ws=\"__WS_PORT__\">page</body></html>"

private func makeHint(text: String, question: String? = nil) -> Hint {
    Hint(createdAt: Date(timeIntervalSince1970: 1_700_000_000), question: question, text: text, status: .completed)
}

private func startServer(token: String = "secret-token", authTimeout: Duration = .seconds(5)) async throws -> (RemoteDisplayServer, RemoteDisplayStatus) {
    let server = RemoteDisplayServer()
    await server.setSnapshotProvider {
        [.snapshot(hints: [RemoteHint(makeHint(text: "Redis with TTL", question: "Cache?"))], session: RemoteSession(HintSessionState(mode: .passive)))]
    }
    try await server.start(RemoteDisplayConfiguration(httpPort: 0, webSocketPort: 0, token: token, pageHTML: testPage, authTimeout: authTimeout))
    return (server, await server.currentStatus)
}

private func connect(port: UInt16) -> URLSessionWebSocketTask {
    let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
    task.resume()
    return task
}

private func receiveText(_ task: URLSessionWebSocketTask) async throws -> String {
    switch try await task.receive() {
    case .string(let text): return text
    case .data(let data): return String(decoding: data, as: UTF8.self)
    @unknown default: return ""
    }
}

private func json(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
}

@Suite(.serialized) struct RemoteDisplayServerTests {
    @Test func servesPageWithInjectedSocketPortAndHealth() async throws {
        let (server, status) = try await startServer()
        defer { Task { await server.stop() } }
        let httpPort = try #require(status.httpPort)
        let socketPort = try #require(status.webSocketPort)
        #expect(httpPort != 0)
        #expect(socketPort != 0)

        let (body, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(httpPort)/")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("data-ws=\"\(socketPort)\""))

        let (health, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(httpPort)/health")!)
        let healthJSON = json(String(decoding: health, as: UTF8.self))
        #expect(healthJSON["ok"] as? Bool == true)
        #expect(healthJSON["wsPort"] as? Int == Int(socketPort))

        let (_, missing) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(httpPort)/secret")!)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
        await server.stop()
    }

    @Test func rejectsWrongTokenAndAcceptsCorrectOne() async throws {
        let (server, status) = try await startServer()
        let socketPort = try #require(status.webSocketPort)

        let wrong = connect(port: socketPort)
        try await wrong.send(.string("{\"type\":\"auth\",\"token\":\"nope\"}"))
        let rejection = try await receiveText(wrong)
        #expect(json(rejection)["type"] as? String == "auth.failed")
        await #expect(throws: (any Error).self) { _ = try await receiveText(wrong) }

        let right = connect(port: socketPort)
        try await right.send(.string("{\"type\":\"auth\",\"token\":\"secret-token\"}"))
        let hello = json(try await receiveText(right))
        #expect(hello["type"] as? String == "hello")
        #expect(hello["version"] as? Int == RemoteOutboundMessage.protocolVersion)
        let snapshot = json(try await receiveText(right))
        #expect(snapshot["type"] as? String == "snapshot")
        let hints = snapshot["hints"] as? [[String: Any]]
        #expect(hints?.first?["text"] as? String == "Redis with TTL")
        #expect(hints?.first?["question"] as? String == "Cache?")
        #expect((snapshot["session"] as? [String: Any])?["mode"] as? String == "passive")

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await server.currentStatus.clientCount != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await server.currentStatus.clientCount == 1)
        right.cancel(with: .normalClosure, reason: nil)
        await server.stop()
    }

    @Test func commandsReachTheStreamAndBroadcastReachesEveryClient() async throws {
        let (server, status) = try await startServer()
        let socketPort = try #require(status.webSocketPort)
        let commands = server.commands()
        let collector = CommandCollector()
        await collector.start(commands)

        let first = connect(port: socketPort)
        let second = connect(port: socketPort)
        for task in [first, second] {
            try await task.send(.string("{\"type\":\"auth\",\"token\":\"secret-token\"}"))
            _ = try await receiveText(task)
            _ = try await receiveText(task)
        }
        try await first.send(.string("{\"type\":\"answer_now\"}"))
        let hintID = UUID()
        try await second.send(.string("{\"type\":\"expand\",\"hintID\":\"\(hintID.uuidString)\"}"))
        try await second.send(.string("{\"type\":\"set_mode\",\"mode\":\"answers\"}"))
        try await first.send(.string("{\"type\":\"reset_context\"}"))
        let received = await collector.waitFor(count: 4)
        #expect(received.contains(.answerNow))
        #expect(received.contains(.expand(hintID: hintID)))
        #expect(received.contains(.setMode(.answers)))
        #expect(received.contains(.resetContext))

        await server.broadcast(.toast(code: "noContext"))
        for task in [first, second] {
            let toast = json(try await receiveText(task))
            #expect(toast["type"] as? String == "toast")
            #expect(toast["code"] as? String == "noContext")
        }
        try await first.send(.string("{\"type\":\"ping\"}"))
        #expect(json(try await receiveText(first))["type"] as? String == "pong")
        first.cancel(with: .normalClosure, reason: nil)
        second.cancel(with: .normalClosure, reason: nil)
        await server.stop()
    }

    @Test func silentClientIsDisconnectedAfterAuthTimeoutAndStopClosesPorts() async throws {
        let (server, status) = try await startServer(authTimeout: .milliseconds(200))
        let socketPort = try #require(status.webSocketPort)
        let httpPort = try #require(status.httpPort)
        let silent = connect(port: socketPort)
        await #expect(throws: (any Error).self) { _ = try await receiveText(silent) }
        #expect(await server.currentStatus.clientCount == 0)

        await server.stop()
        #expect(await server.currentStatus == .stopped)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(httpPort)/")!)
        request.timeoutInterval = 2
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(for: request) }
    }
}

actor CommandCollector {
    private(set) var received: [RemoteCommand] = []

    func start(_ stream: AsyncStream<RemoteCommand>) {
        Task { [weak self] in
            for await command in stream {
                await self?.append(command)
            }
        }
    }

    private func append(_ command: RemoteCommand) { received.append(command) }

    func waitFor(count: Int, timeout: Duration = .seconds(3)) async -> [RemoteCommand] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while received.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return received
    }
}

@Suite struct RemoteMessageCodecTests {
    @Test func everyFeedEventHasAStableTypeAndKeepsContent() throws {
        let hint = Hint(createdAt: Date(timeIntervalSince1970: 1_700_000_000), question: "Q", text: "A", status: .streaming, expansion: HintExpansion(text: "deep", status: .failed("rate_limited")))
        let pairs: [(HintFeedEvent, String)] = [
            (.snapshot(hints: [hint], session: HintSessionState(mode: .answers, phase: .streaming, provider: .anthropicClaude, modelID: "claude-opus-5-5", expertAreas: ["PHP"])), "snapshot"),
            (.hintStarted(hint), "hint.started"),
            (.hintUpdated(hint), "hint.updated"),
            (.hintCompleted(hint), "hint.completed"),
            (.expansionUpdated(hintID: hint.id, HintExpansion(text: "x", status: .completed)), "hint.expansion"),
            (.sessionChanged(HintSessionState()), "session"),
            (.notice(.noContext), "toast"),
        ]
        for (event, expectedType) in pairs {
            let data = RemoteMessageCodec.encode(.from(event))
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["type"] as? String == expectedType)
        }
        let snapshotData = RemoteMessageCodec.encode(.from(pairs[0].0))
        let snapshot = try #require(try JSONSerialization.jsonObject(with: snapshotData) as? [String: Any])
        let encodedHint = try #require((snapshot["hints"] as? [[String: Any]])?.first)
        #expect(encodedHint["text"] as? String == "A")
        #expect(encodedHint["status"] as? String == "streaming")
        #expect(encodedHint["createdAt"] as? String == "2023-11-14T22:13:20Z")
        #expect((encodedHint["expansion"] as? [String: Any])?["error"] as? String == "rate_limited")
        let session = try #require(snapshot["session"] as? [String: Any])
        #expect(session["provider"] as? String == "anthropicClaude")
        #expect(session["expertAreas"] as? [String] == ["PHP"])
        #expect(json(String(decoding: RemoteMessageCodec.encode(.toast(code: "noContext")), as: UTF8.self))["code"] as? String == "noContext")
    }

    @Test func decodesClientCommandsAndRejectsGarbage() {
        let id = UUID()
        #expect(RemoteMessageCodec.decode(Data("{\"type\":\"auth\",\"token\":\"t\"}".utf8)) == .auth(token: "t"))
        #expect(RemoteMessageCodec.decode(Data("{\"type\":\"answer_now\"}".utf8)) == .answerNow)
        #expect(RemoteMessageCodec.decode(Data("{\"type\":\"expand\",\"hintID\":\"\(id.uuidString)\"}".utf8)) == .expand(hintID: id))
        #expect(RemoteMessageCodec.decode(Data("{\"type\":\"set_mode\",\"mode\":\"passive\"}".utf8)) == .setMode(.passive))
        #expect(RemoteMessageCodec.decode(Data("{\"type\":\"set_mode\",\"mode\":\"bogus\"}".utf8)) == nil)
        #expect(RemoteMessageCodec.decode(Data("{\"type\":\"expand\"}".utf8)) == nil)
        #expect(RemoteMessageCodec.decode(Data("not json".utf8)) == nil)
    }

    @Test func httpResponderRoutes() {
        let page = RemoteHTTPResponder.respond(to: "GET /?t=abc HTTP/1.1\r\nHost: x\r\n\r\n", page: "<p>__WS_PORT__</p>", webSocketPort: 8766)
        let text = String(decoding: page, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK"))
        #expect(text.contains("<p>8766</p>"))
        #expect(text.contains("Content-Type: text/html"))
        #expect(String(decoding: RemoteHTTPResponder.respond(to: "POST / HTTP/1.1\r\n\r\n", page: "", webSocketPort: nil), as: UTF8.self).hasPrefix("HTTP/1.1 405"))
        #expect(String(decoding: RemoteHTTPResponder.respond(to: "GET /nope HTTP/1.1\r\n\r\n", page: "", webSocketPort: nil), as: UTF8.self).hasPrefix("HTTP/1.1 404"))
        #expect(String(decoding: RemoteHTTPResponder.respond(to: "", page: "", webSocketPort: nil), as: UTF8.self).hasPrefix("HTTP/1.1 400"))
    }

    @Test func constantTimeComparisonOnlyAcceptsExactMatch() {
        #expect(RemoteDisplayServer.constantTimeEquals("abc", "abc"))
        #expect(!RemoteDisplayServer.constantTimeEquals("abc", "abd"))
        #expect(!RemoteDisplayServer.constantTimeEquals("abc", "abcd"))
        #expect(!RemoteDisplayServer.constantTimeEquals("", ""))
    }
}
