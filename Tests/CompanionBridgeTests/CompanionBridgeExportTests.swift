import CompanionProtocol
import CompanionServer
import Domain
import Foundation
import Testing
@testable import CompanionBridge

private struct ExportFailure: Error {}

private actor FakeExporter: SessionDocumentExporting {
    let known: SessionID
    var failing = false
    private(set) var requested: [SessionID] = []

    init(known: SessionID) {
        self.known = known
    }

    func setFailing() {
        failing = true
    }

    func exportDocument(sessionID: SessionID) async throws -> SessionExportDocument? {
        requested.append(sessionID)
        if failing { throw ExportFailure() }
        return sessionID == known ? SessionExportDocument(filename: "s.md", markdown: "# S\n") : nil
    }
}

@Suite struct CompanionBridgeExportTests {
    @Test func exportCapabilityOnlyWithExporter() {
        #expect(!CompanionBridge(control: FakeDomainControl()).capabilities.contains("export.request"))
        let exporter = FakeExporter(known: SessionID())
        #expect(CompanionBridge(control: FakeDomainControl(), exporter: exporter).capabilities.contains("export.request"))
    }

    @Test func exportMapsDocumentsAndErrors() async {
        let id = SessionID()
        let exporter = FakeExporter(known: id)
        let bridge = CompanionBridge(control: FakeDomainControl(), exporter: exporter)
        #expect(await bridge.exportDocument(sessionId: id.rawValue.uuidString) == .document(CompanionExportDocument(filename: "s.md", markdown: "# S\n")))
        #expect(await bridge.exportDocument(sessionId: "not-a-uuid") == .rejected(code: "unknown_session"))
        #expect(await bridge.exportDocument(sessionId: UUID().uuidString) == .rejected(code: "unknown_session"))
        await exporter.setFailing()
        #expect(await bridge.exportDocument(sessionId: id.rawValue.uuidString) == .rejected(code: "export_failed"))
        #expect(await exporter.requested.count == 3)
        #expect(await CompanionBridge(control: FakeDomainControl()).exportDocument(sessionId: id.rawValue.uuidString) == .rejected(code: "not_available"))
    }
}
