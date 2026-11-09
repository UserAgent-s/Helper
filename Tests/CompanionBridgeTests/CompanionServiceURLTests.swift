import CompanionProtocol
import CompanionServer
import Foundation
import Testing
@testable import CompanionBridge

final class FakeNetworkMonitor: CompanionNetworkMonitoring, @unchecked Sendable {
    let stream: AsyncStream<[String]>
    let continuation: AsyncStream<[String]>.Continuation

    init() {
        (stream, continuation) = AsyncStream<[String]>.makeStream()
    }

    func addressChanges() -> AsyncStream<[String]> {
        stream
    }
}

final class MutableAddresses: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String]

    init(_ value: [String]) {
        self.value = value
    }

    func set(_ newValue: [String]) {
        lock.withLock { value = newValue }
    }

    func get() -> [String] {
        lock.withLock { value }
    }
}

@Suite(.serialized) struct CompanionServiceURLTests {
    @Test func panelURLsKeepOnlyPrivateIPv4WithoutDuplicates() {
        let urls = CompanionPanelURL.urls(addresses: ["127.0.0.1", "192.168.1.33", "fe80::1", "10.0.0.5", "192.168.1.33", "8.8.8.8", "172.20.1.1", "172.40.1.1"], port: 47057)
        #expect(urls == ["http://192.168.1.33:47057/", "http://10.0.0.5:47057/", "http://172.20.1.1:47057/"])
    }

    @Test func urlsFollowNetworkChangesWhileRunning() async throws {
        let monitor = FakeNetworkMonitor()
        let addresses = MutableAddresses(["192.168.1.33"])
        let bridge = CompanionBridge(control: FakeDomainControl())
        let service = CompanionService(
            pairing: PairingStore(storage: InMemoryPairedDeviceStore()),
            bridge: bridge,
            transport: FlyingFoxCompanionTransport(localAddresses: { [] }),
            configuration: CompanionServerConfiguration(preferredPort: 0, bind: .loopback),
            serverVersion: "test",
            addresses: { addresses.get() },
            networkMonitor: monitor
        )
        #expect(await service.panelURLs().isEmpty)
        let port = try await service.start()
        #expect(await service.panelURLs() == ["http://192.168.1.33:\(port)/"])

        var updates = service.panelURLUpdates().makeAsyncIterator()
        addresses.set(["10.1.2.3"])
        monitor.continuation.yield(["10.1.2.3"])
        #expect(await updates.next() == ["http://10.1.2.3:\(port)/"])
        await service.stop()
        #expect(await service.panelURLs().isEmpty)
        withExtendedLifetime(bridge) {}
    }
}
