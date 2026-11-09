import CompanionProtocol
import CompanionServer
import Foundation
import Testing
@testable import UserAgent057

actor FakePairingService: CompanionPairingServicing {
    var running: Bool
    var urls: [String]
    let expiresAt: Date
    private(set) var issued = 0
    private(set) var cancelled = 0
    private var continuations: [AsyncStream<PairedDevice>.Continuation] = []

    init(running: Bool = true, urls: [String] = ["http://192.168.1.10:47057/"], expiresAt: Date) {
        self.running = running
        self.urls = urls
        self.expiresAt = expiresAt
    }

    func setRunning(_ value: Bool) { running = value }

    func isServerRunning() async -> Bool { running }

    func panelURLs() async -> [String] { urls }

    func issuePairingCodes() async -> (qr: PairingCode, numeric: PairingCode) {
        issued += 1
        return (
            PairingCode(kind: .qr128, value: "QRVALUE\(issued)", expiresAt: expiresAt),
            PairingCode(kind: .numeric6, value: "12345\(issued)", expiresAt: expiresAt)
        )
    }

    func cancelPairingCodes() async { cancelled += 1 }

    func pairingEvents() async -> AsyncStream<PairedDevice> {
        let (stream, continuation) = AsyncStream<PairedDevice>.makeStream()
        continuations.append(continuation)
        return stream
    }

    func emit(_ name: String) {
        let device = PairedDevice(deviceId: "d-\(name)", name: name, tokenHash: "h", createdAt: Date())
        continuations.forEach { $0.yield(device) }
    }
}

final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 2_000_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@MainActor
@Suite struct CompanionPairingViewModelTests {
    private func make(service: FakePairingService, clock: ManualClock, enable: @escaping @MainActor () async -> Bool = { false }) -> CompanionPairingViewModel {
        CompanionPairingViewModel(service: service, enableServer: enable, now: { clock.now }, closeDelay: .zero)
    }

    @Test func beginShowsMaskedCodeUntilRevealed() async {
        let clock = ManualClock()
        let service = FakePairingService(expiresAt: clock.now.addingTimeInterval(300))
        let model = make(service: service, clock: clock)
        await model.begin(startTicker: false)
        #expect(model.phase == .ready)
        #expect(model.isRevealed == false)
        #expect(model.maskedNumericCode == "••• •••")
        #expect(model.qrImage == nil)
        #expect(model.pairingURL == "http://192.168.1.10:47057/#pair=QRVALUE1")
        #expect(model.remainingSeconds == 300)
        model.reveal()
        #expect(model.maskedNumericCode == "123 451")
        let image = model.qrImage
        #expect(image.map { $0.size.width == $0.size.height && $0.size.width >= 150 } == true)
        model.hide()
        #expect(model.qrImage == nil)
        await model.end()
    }

    @Test func codeExpiryHidesCodeAndRegenerateIssuesNewOne() async {
        let clock = ManualClock()
        let service = FakePairingService(expiresAt: clock.now.addingTimeInterval(300))
        let model = make(service: service, clock: clock)
        await model.begin(startTicker: false)
        model.reveal()
        clock.advance(299.2)
        model.tick()
        #expect(model.phase == .ready)
        #expect(model.remainingSeconds == 1)
        clock.advance(1)
        model.tick()
        #expect(model.phase == .expired)
        #expect(model.isRevealed == false)
        #expect(model.pairingURL == nil)
        #expect(model.maskedNumericCode == "")
        await model.regenerate()
        #expect(await service.issued == 2)
        #expect(await service.cancelled == 1)
        await model.end()
    }

    @Test func firstSuccessfulPairingClosesWindow() async throws {
        let clock = ManualClock()
        let service = FakePairingService(expiresAt: clock.now.addingTimeInterval(300))
        let model = make(service: service, clock: clock)
        await model.begin(startTicker: false)
        model.reveal()
        await service.emit("Phone")
        for _ in 0..<200 where !model.shouldClose {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.shouldClose)
        #expect(model.phase == .paired(deviceName: "Phone"))
        #expect(model.pairingURL == nil)
        #expect(await service.cancelled == 1)
        await model.end()
        #expect(await service.cancelled == 1)
    }

    @Test func serverOffOffersToEnableAndThenIssuesCodes() async {
        let clock = ManualClock()
        let service = FakePairingService(running: false, expiresAt: clock.now.addingTimeInterval(300))
        let model = make(service: service, clock: clock) {
            await service.setRunning(true)
            return true
        }
        await model.begin(startTicker: false)
        #expect(model.phase == .serverOff)
        #expect(await service.issued == 0)
        await model.turnOnServer()
        #expect(model.phase == .ready)
        await model.end()
        #expect(await service.cancelled == 1)
        #expect(model.phase == .idle)
    }

    @Test func noLANAddressDoesNotIssueCodes() async {
        let clock = ManualClock()
        let service = FakePairingService(urls: [], expiresAt: clock.now.addingTimeInterval(300))
        let model = make(service: service, clock: clock)
        await model.begin(startTicker: false)
        #expect(model.phase == .noNetworkAddress)
        #expect(await service.issued == 0)
    }

    @Test func navigationGateRequiresExplicitRequest() {
        let navigation = AppNavigationState()
        #expect(navigation.consumePairingRequest() == false)
        navigation.requestPairing()
        #expect(navigation.isShowingPairing)
        #expect(navigation.consumePairingRequest())
        #expect(navigation.consumePairingRequest() == false)
    }

    @Test func companionPortSettingFallsBackToDefault() {
        let defaults = UserDefaults(suiteName: "companion-port-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)
        #expect(store.companionPort == 47057)
        store.companionPort = 50000
        #expect(store.companionConfiguration.preferredPort == 50000)
        defaults.set(80, forKey: "com.local.UserAgent057.settings.companion.port")
        #expect(store.companionPort == 47057)
        store.companionLoopbackOnly = true
        #expect(store.companionConfiguration.bind == .loopback)
    }
}
