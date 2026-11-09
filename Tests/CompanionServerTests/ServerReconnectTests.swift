import CompanionProtocol
import Foundation
import Testing
@testable import CompanionServer

extension ServerIntegrationTests {
    private func isSnapshot(_ event: ServerEvent) -> Bool {
        if case .stateSnapshot = event { true } else { false }
    }

    private func json(_ envelope: ServerEnvelope) throws -> String {
        String(decoding: try CompanionCodec.encode(envelope), as: UTF8.self)
    }

    @Test func reconnectReplay() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let grant = try await server.token()
        let first = try await server.connect(token: grant.deviceToken)
        var received: [ServerEnvelope] = [try await first.next()]
        received.append(try await first.next(where: isSnapshot))

        var projector = AnswerStreamProjector(answerId: "r1", trigger: .manual)
        await server.hub.publish(.answerStarted(.init(answerId: "r1", trigger: .manual, startedAt: 1)))
        await server.hub.publish(try #require(projector.update(accumulated: "1. Один\n")))
        let started = try await first.next()
        received.append(started)
        received.append(try await first.next())
        first.close()
        try await waitFor { await server.hub.authenticatedDeviceIds.isEmpty }

        await server.hub.publish(try #require(projector.update(accumulated: "1. Один\n2. Два")))
        for event in projector.finish(.completed) {
            await server.hub.publish(event)
        }

        let second = try await server.connect(token: grant.deviceToken, lastSeq: started.seq)
        let hello = try await second.next()
        guard case .helloOK(let ok) = hello.event else { Issue.record("expected hello.ok"); return }
        #expect(ok.replayed)
        received.append(hello)
        var replayed: [ServerEnvelope] = []
        while true {
            let envelope = try await second.next()
            #expect(!isSnapshot(envelope.event))
            replayed.append(envelope)
            if case .answerDone = envelope.event { break }
        }
        #expect(replayed.map(\.type) == ["answer.delta", "answer.delta", "answer.done"])
        #expect(replayed.map(\.seq) == replayed.map(\.seq).sorted())
        #expect(replayed.first?.seq == received.last(where: { $0.type == "answer.delta" })?.seq)
        received.append(contentsOf: replayed)
        second.close()

        let store = try WebModuleContext(modules: ["store.js"])
        try store.run("globalThis.state = initialState(); return null;")
        for (index, envelope) in received.enumerated() {
            store.set("e\(index)", json: try json(envelope))
            try store.run("globalThis.state = applyEnvelope(globalThis.state, e\(index)); return null;")
        }
        let state = try #require(try store.run("return globalThis.state;") as? [String: Any])
        let answer = try #require(state["answer"] as? [String: Any])
        #expect(answer["text"] as? String == "1. Один\n2. Два")
        #expect(answer["status"] as? String == "completed")
        let points = try #require(answer["points"] as? [[String: Any]])
        #expect(points.map { $0["pointId"] as? String } == ["r1.0", "r1.1"])
        #expect(points.allSatisfy { $0["open"] as? Bool == false })
        #expect(state["resyncNeeded"] as? Bool == false)
        #expect(state["lastSeq"] as? Int == replayed.last?.seq)
    }

    @Test func snapshotWhenEvicted() async throws {
        let server = try await ServerFixture.start(replayCapacity: 3)
        defer { Task { await server.transport.stop() } }
        let grant = try await server.token()
        let first = try await server.connect(token: grant.deviceToken)
        let snapshot = try await first.next(where: isSnapshot)
        first.close()
        try await waitFor { await server.hub.authenticatedDeviceIds.isEmpty }
        for index in 0..<6 {
            await server.hub.publish(.notice(.init(code: "n\(index)", severity: .info)))
        }

        let evicted = try await server.connect(token: grant.deviceToken, lastSeq: snapshot.seq)
        guard case .helloOK(let ok) = try await evicted.next().event else { Issue.record("expected hello.ok"); return }
        #expect(ok.replayed == false)
        #expect(isSnapshot(try await evicted.next().event))
        evicted.close()
        try await waitFor { await server.hub.authenticatedDeviceIds.isEmpty }

        let restarted = try await server.connect(token: grant.deviceToken, lastSeq: 1_000_000)
        guard case .helloOK(let fresh) = try await restarted.next().event else { Issue.record("expected hello.ok"); return }
        #expect(fresh.replayed == false)
        #expect(isSnapshot(try await restarted.next().event))
        restarted.close()
    }
}
