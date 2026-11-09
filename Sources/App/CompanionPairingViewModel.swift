import AppKit
import CompanionBridge
import CompanionProtocol
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Observation

protocol CompanionPairingServicing: Sendable {
    func isServerRunning() async -> Bool
    func panelURLs() async -> [String]
    func issuePairingCodes() async -> (qr: PairingCode, numeric: PairingCode)
    func cancelPairingCodes() async
    func pairingEvents() async -> AsyncStream<PairedDevice>
}

extension CompanionService: CompanionPairingServicing {
    func isServerRunning() async -> Bool {
        isRunning
    }

    func issuePairingCodes() async -> (qr: PairingCode, numeric: PairingCode) {
        let store = pairingStore
        return (await store.issueCode(.qr128), await store.issueCode(.numeric6))
    }

    func cancelPairingCodes() async {
        let store = pairingStore
        await store.cancelCode(.qr128)
        await store.cancelCode(.numeric6)
    }

    func pairingEvents() async -> AsyncStream<PairedDevice> {
        await pairingStore.pairingEvents()
    }
}

@MainActor
@Observable
final class CompanionPairingViewModel {
    enum Phase: Equatable {
        case idle
        case serverOff
        case noNetworkAddress
        case ready
        case expired
        case paired(deviceName: String)
    }

    private let service: any CompanionPairingServicing
    private let enableServer: @MainActor () async -> Bool
    private let now: () -> Date
    private let closeDelay: Duration
    private var eventsTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    private(set) var phase: Phase = .idle
    private(set) var numericCode: String?
    private(set) var pairingURL: String?
    private(set) var panelURL: String?
    private(set) var expiresAt: Date?
    private(set) var remainingSeconds = 0
    private(set) var isRevealed = false
    private(set) var shouldClose = false

    init(
        service: any CompanionPairingServicing,
        enableServer: @escaping @MainActor () async -> Bool,
        now: @escaping () -> Date = { Date() },
        closeDelay: Duration = .seconds(1.5)
    ) {
        self.service = service
        self.enableServer = enableServer
        self.now = now
        self.closeDelay = closeDelay
    }

    var maskedNumericCode: String {
        guard let numericCode else { return "" }
        return isRevealed ? String(numericCode.prefix(3)) + " " + String(numericCode.dropFirst(3)) : "••• •••"
    }

    func begin(startTicker: Bool = true) async {
        shouldClose = false
        isRevealed = false
        guard await service.isServerRunning() else {
            clearCodes()
            phase = .serverOff
            return
        }
        guard let url = await service.panelURLs().first else {
            clearCodes()
            phase = .noNetworkAddress
            return
        }
        let codes = await service.issuePairingCodes()
        panelURL = url
        pairingURL = url + "#pair=" + codes.qr.value
        numericCode = codes.numeric.value
        expiresAt = min(codes.qr.expiresAt, codes.numeric.expiresAt)
        phase = .ready
        tick()
        await observePairings()
        if startTicker { startTicking() }
    }

    func turnOnServer() async {
        guard await enableServer() else { return }
        await begin()
    }

    func reveal() {
        guard phase == .ready else { return }
        isRevealed = true
    }

    func hide() {
        isRevealed = false
    }

    func regenerate() async {
        await service.cancelPairingCodes()
        await begin()
    }

    func tick() {
        guard phase == .ready, let expiresAt else { return }
        let remaining = Int(expiresAt.timeIntervalSince(now()).rounded(.up))
        remainingSeconds = max(0, remaining)
        if remaining <= 0 {
            phase = .expired
            isRevealed = false
            numericCode = nil
            pairingURL = nil
        }
    }

    func end() async {
        eventsTask?.cancel()
        eventsTask = nil
        tickTask?.cancel()
        tickTask = nil
        if case .paired = phase {} else {
            await service.cancelPairingCodes()
        }
        clearCodes()
        phase = .idle
    }

    func handlePaired(_ device: PairedDevice) async {
        guard phase == .ready else { return }
        phase = .paired(deviceName: device.name)
        isRevealed = false
        numericCode = nil
        pairingURL = nil
        await service.cancelPairingCodes()
        tickTask?.cancel()
        try? await Task.sleep(for: closeDelay)
        shouldClose = true
    }

    var qrImage: NSImage? {
        guard isRevealed, let pairingURL else { return nil }
        return QRCodeRenderer.image(for: pairingURL, side: 220)
    }

    private func observePairings() async {
        eventsTask?.cancel()
        let events = await service.pairingEvents()
        eventsTask = Task { [weak self] in
            for await device in events {
                await self?.handlePaired(device)
            }
        }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func clearCodes() {
        numericCode = nil
        pairingURL = nil
        panelURL = nil
        expiresAt = nil
        remainingSeconds = 0
    }
}

enum QRCodeRenderer {
    static func image(for text: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = max(1, (side / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
