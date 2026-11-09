import CompanionProtocol
import Foundation
import Testing
@testable import CompanionServer

@Suite(.serialized) struct HistoryHubTests {
    @Test func historyListAnswersOnlyTheRequesterThenAcks() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let socket = try await server.authenticated("A")
        let other = try await server.authenticated("B")
        try await socket.send(ClientCommand(cmdId: "c-list", action: .historyList(.init(q: "kafka"))))
        let page = try await socket.next(where: { if case .historyPage = $0 { true } else { false } })
        guard case .historyPage(let data) = page.event else { Issue.record("no page"); return }
        #expect(data.q == "kafka")
        #expect(data.items.map(\.sessionId) == ["ses-ok"])
        let ack = try await socket.next(where: { if case .ack = $0 { true } else { false } })
        #expect(ack.event == .ack(.init(cmdId: "c-list", ok: true)))

        try await socket.send(ClientCommand(cmdId: "c-get", action: .historyGet(.init(sessionId: "ses-ok"))))
        let detail = try await socket.next(where: { if case .historySession = $0 { true } else { false } })
        guard case .historySession(let session) = detail.event else { Issue.record("no session"); return }
        #expect(session.sessionId == "ses-ok")

        try await socket.send(ClientCommand(cmdId: "c-missing", action: .historyGet(.init(sessionId: "ses-missing"))))
        let missing = try await socket.next(where: { if case .ack(let a) = $0 { a.cmdId == "c-missing" } else { false } })
        #expect(missing.event == .ack(.init(cmdId: "c-missing", ok: false, code: "unknown_session")))

        try await other.send(ClientCommand(cmdId: "c-ping", action: .ping(.init(nonce: "p"))))
        let first = try await other.next(where: { event in
            switch event {
            case .historyPage, .historySession, .pong: true
            default: false
            }
        })
        #expect(first.event == .pong(.init(nonce: "p")))
        socket.close()
        other.close()
    }

    @Test func oversizedHistoryIsRejectedInsteadOfSilentlyDropped() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let socket = try await server.authenticated()
        try await socket.send(ClientCommand(cmdId: "c-huge", action: .historyGet(.init(sessionId: "ses-huge"))))
        let ack = try await socket.next(where: { if case .ack = $0 { true } else { false } })
        #expect(ack.event == .ack(.init(cmdId: "c-huge", ok: false, code: "history_too_large")))
        socket.close()
    }

    @Test func historyBeforeHelloClosesWith4401() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let socket = TestSocket(port: server.port)
        try await socket.send(ClientCommand(cmdId: "c1", action: .historyList(.init())))
        #expect(try await socket.closeCode() == 4401)
    }

    @Test func historyEventsAreNeverReplayed() {
        #expect(!ServerEvent.historyPage(.init(items: [])).isReplayable)
        #expect(!ServerEvent.historySession(.init(sessionId: "s", kind: "assistant", title: nil, startedAt: 0, endedAt: nil, status: "completed", summary: nil, qa: [], expansions: [], transcript: [], moments: [], screens: [], truncated: false)).isReplayable)
    }

    @Test func historyArgumentsAreValidated() throws {
        #expect(throws: CompanionProtocolError.invalidArgument(field: "cursor", reason: "invalid_characters")) {
            try ClientCommand(cmdId: "c", action: .historyList(.init(cursor: "a b"))).validate()
        }
        #expect(throws: CompanionProtocolError.invalidArgument(field: "limit", reason: "out_of_range")) {
            try ClientCommand(cmdId: "c", action: .historyList(.init(limit: 0))).validate()
        }
        #expect(throws: CompanionProtocolError.invalidArgument(field: "limit", reason: "out_of_range")) {
            try ClientCommand(cmdId: "c", action: .historyList(.init(limit: 101))).validate()
        }
        #expect(throws: CompanionProtocolError.invalidArgument(field: "q", reason: "too_long")) {
            try ClientCommand(cmdId: "c", action: .historyList(.init(q: String(repeating: "q", count: 201)))).validate()
        }
        #expect(throws: CompanionProtocolError.invalidArgument(field: "sessionId", reason: "invalid_characters")) {
            try ClientCommand(cmdId: "c", action: .historyGet(.init(sessionId: "../x"))).validate()
        }
        let bare = try CompanionCodec.decodeCommand(#"{"v":1,"cmdId":"c","name":"history.list"}"#)
        #expect(bare.action == .historyList(.init()))
    }
}
