import CompanionProtocol
import Foundation
import Testing
@testable import CompanionServer

private struct SequenceRandom: CompanionRandomSource {
    func bytes(count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...255) }
    }
}

@Suite struct ExportTicketStoreTests {
    private let document = CompanionExportDocument(filename: "a.md", markdown: "# A\n")
    private let start = Date(timeIntervalSince1970: 1_762_700_000)

    @Test func exportTicketSingleUse() {
        var tickets = CompanionExportTickets(random: SequenceRandom())
        let issued = tickets.issue(sessionId: "ses", deviceId: "dev", document: document, now: start)
        #expect(issued.ticket.count == 43)
        #expect(issued.expiresAt == start.addingTimeInterval(CompanionExportTickets.defaultLifetime))
        #expect(tickets.redeem(sessionId: "ses", ticket: issued.ticket, now: start) == document)
        #expect(tickets.redeem(sessionId: "ses", ticket: issued.ticket, now: start) == nil)
        #expect(tickets.count == 0)
    }

    @Test func ticketBoundToSessionAndBurnedOnMismatch() {
        var tickets = CompanionExportTickets()
        let issued = tickets.issue(sessionId: "ses", deviceId: "dev", document: document, now: start)
        #expect(tickets.redeem(sessionId: "other", ticket: issued.ticket, now: start) == nil)
        #expect(tickets.redeem(sessionId: "ses", ticket: issued.ticket, now: start) == nil)
        #expect(tickets.redeem(sessionId: "ses", ticket: "", now: start) == nil)
    }

    @Test func ticketExpires() {
        var tickets = CompanionExportTickets(lifetime: 60)
        let issued = tickets.issue(sessionId: "ses", deviceId: "dev", document: document, now: start)
        #expect(tickets.redeem(sessionId: "ses", ticket: issued.ticket, now: start.addingTimeInterval(60)) == nil)
    }

    @Test func capacityEvictsOldestAndRevocationDropsDeviceTickets() {
        var tickets = CompanionExportTickets(capacity: 2)
        let first = tickets.issue(sessionId: "s1", deviceId: "a", document: document, now: start)
        let second = tickets.issue(sessionId: "s2", deviceId: "b", document: document, now: start)
        let third = tickets.issue(sessionId: "s3", deviceId: "a", document: document, now: start)
        #expect(tickets.redeem(sessionId: "s1", ticket: first.ticket, now: start) == nil)
        tickets.revoke(deviceId: "a")
        #expect(tickets.redeem(sessionId: "s3", ticket: third.ticket, now: start) == nil)
        #expect(tickets.redeem(sessionId: "s2", ticket: second.ticket, now: start) == document)
    }

    @Test func exportPathParsing() {
        #expect(CompanionHTTPHandler.exportSessionId(fromPath: "/export/8F0C6B2A-3D4E.md") == "8F0C6B2A-3D4E")
        #expect(CompanionHTTPHandler.exportSessionId(fromPath: "/export/.md") == nil)
        #expect(CompanionHTTPHandler.exportSessionId(fromPath: "/export/../app.js.md") == nil)
        #expect(CompanionHTTPHandler.exportSessionId(fromPath: "/export/a%2Fb.md") == nil)
        #expect(CompanionHTTPHandler.exportSessionId(fromPath: "/export/ses.txt") == nil)
        #expect(CompanionHTTPHandler.attachment(filename: "x\"; y.md") == "attachment; filename=\"xy.md\"")
    }
}

@Suite(.serialized) struct ExportRouteIntegrationTests {
    @Test func exportTicketDownloadsOnceOverHTTP() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let socket = try await server.authenticated()
        try await socket.send(ClientCommand(cmdId: "c-export", action: .exportRequest(.init(sessionId: "ses-ok"))))
        let readyEnvelope = try await socket.next(where: { if case .exportReady = $0 { true } else { false } })
        guard case .exportReady(let ready) = readyEnvelope.event else { Issue.record("no export.ready"); return }
        let ack = try await socket.next(where: { if case .ack = $0 { true } else { false } })
        #expect(ack.event == .ack(.init(cmdId: "c-export", ok: true)))
        #expect(ready.sessionId == "ses-ok")
        #expect(ready.filename == "UserAgent057-2025-11-09-1500.md")
        #expect(ready.url.hasPrefix("/export/ses-ok.md?t="))
        #expect(await server.hub.outstandingExportTickets == 1)

        let (response, data) = try await server.http(ready.url)
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "text/markdown; charset=utf-8")
        #expect(response.value(forHTTPHeaderField: "Content-Disposition") == "attachment; filename=\"UserAgent057-2025-11-09-1500.md\"")
        #expect(response.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(String(decoding: data, as: UTF8.self) == "# Сессия\n")

        let (again, _) = try await server.http(ready.url)
        #expect(again.statusCode == 404)
        #expect(await server.hub.outstandingExportTickets == 0)
        socket.close()
    }

    @Test func unknownSessionIsRejectedWithoutTicket() async throws {
        let server = try await ServerFixture.start()
        defer { Task { await server.transport.stop() } }
        let socket = try await server.authenticated()
        try await socket.send(ClientCommand(cmdId: "c-missing", action: .exportRequest(.init(sessionId: "ses-missing"))))
        let ack = try await socket.next(where: { if case .ack = $0 { true } else { false } })
        #expect(ack.event == .ack(.init(cmdId: "c-missing", ok: false, code: "unknown_session")))
        #expect(await server.hub.outstandingExportTickets == 0)
        let (response, _) = try await server.http("/export/ses-ok.md?t=guess")
        #expect(response.statusCode == 404)
        socket.close()
    }

    @Test func exportReadyIsNeverReplayed() {
        #expect(!ServerEvent.exportReady(.init(sessionId: "s", url: "/export/s.md?t=x", filename: "s.md", expiresAt: 0)).isReplayable)
    }
}
