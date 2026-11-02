import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Domain
import Foundation
import Observation
import RemoteDisplay

@MainActor
@Observable
final class RemoteDisplayCoordinator {
    private let server: RemoteDisplayServer
    private let hintFeed: HintFeed
    private let manualAnswerTrigger: ManualAnswerTrigger
    private let answersController: any AnswerSessionControlling
    private let modeCoordinator: ModeCoordinator
    private let settingsStore: AppSettingsStore
    private let pageHTML: String
    private let bonjourName: String?

    private(set) var status = RemoteDisplayStatus.stopped
    private(set) var startError: String?
    private var listeners: [Task<Void, Never>] = []
    private var applying = false

    init(
        server: RemoteDisplayServer = RemoteDisplayServer(),
        hintFeed: HintFeed,
        manualAnswerTrigger: ManualAnswerTrigger,
        answersController: any AnswerSessionControlling,
        modeCoordinator: ModeCoordinator,
        settingsStore: AppSettingsStore,
        pageHTML: String,
        bonjourName: String? = "MeetingAssistant"
    ) {
        self.server = server
        self.hintFeed = hintFeed
        self.manualAnswerTrigger = manualAnswerTrigger
        self.answersController = answersController
        self.modeCoordinator = modeCoordinator
        self.settingsStore = settingsStore
        self.pageHTML = pageHTML
        self.bonjourName = bonjourName
        listeners.append(Task { [weak self, server] in
            for await status in server.statusUpdates() {
                guard let self else { return }
                self.status = status
            }
        })
    }

    var isEnabled: Bool {
        get { settingsStore.remoteDisplayEnabled }
        set {
            settingsStore.remoteDisplayEnabled = newValue
            Task { await applySettings() }
        }
    }

    var port: Int {
        get { settingsStore.remoteDisplayPort }
        set {
            settingsStore.remoteDisplayPort = newValue
            Task { await applySettings(restart: true) }
        }
    }

    var token: String {
        settingsStore.remoteDisplayToken
    }

    func regenerateToken() {
        settingsStore.regenerateRemoteDisplayToken()
        Task { await applySettings(restart: true) }
    }

    var urls: [URL] {
        guard let port = status.httpPort else { return [] }
        return LocalNetworkAddresses.ipv4().compactMap { URL(string: "http://\($0):\(port)/?t=\(token)") }
    }

    var qrImage: NSImage? {
        guard let url = urls.first else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    func applySettings(restart: Bool = false) async {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        let running = await server.currentStatus.isRunning
        if !settingsStore.remoteDisplayEnabled {
            if running { await server.stop() }
            stopBridges()
            startError = nil
            return
        }
        if running, !restart { return }
        if running { await server.stop() }
        stopBridges()
        let base = UInt16(clamping: settingsStore.remoteDisplayPort)
        let configuration = RemoteDisplayConfiguration(
            httpPort: base,
            webSocketPort: base &+ 1,
            token: settingsStore.remoteDisplayToken,
            pageHTML: pageHTML,
            bonjourName: bonjourName
        )
        let hintFeed = self.hintFeed
        await server.setSnapshotProvider {
            let hints = await hintFeed.currentHints
            let session = await hintFeed.currentSession
            return [RemoteOutboundMessage.from(.snapshot(hints: hints, session: session))]
        }
        do {
            try await server.start(configuration)
            startError = nil
            startBridges()
        } catch {
            startError = Self.describe(error)
        }
    }

    private func startBridges() {
        let server = self.server
        let hintFeed = self.hintFeed
        listeners.append(Task { [weak self] in
            for await event in hintFeed.events() {
                guard self != nil else { return }
                if case .snapshot = event { continue }
                await server.broadcast(RemoteOutboundMessage.from(event))
            }
        })
        listeners.append(Task { [weak self] in
            for await command in server.commands() {
                guard let self else { return }
                await self.perform(command)
            }
        })
    }

    private func stopBridges() {
        for task in listeners.dropFirst() { task.cancel() }
        listeners = Array(listeners.prefix(1))
    }

    private func perform(_ command: RemoteCommand) async {
        switch command {
        case .answerNow:
            await manualAnswerTrigger.fire()
        case .expand(let hintID):
            await hintFeed.expand(hintID: hintID)
        case .resetContext:
            await answersController.resetContext()
        case .setMode(let mode):
            _ = await modeCoordinator.requestTransition(to: mode, reason: "remote_display")
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case RemoteDisplayError.alreadyRunning: loc("сервер уже запущен")
        case RemoteDisplayError.invalidPort(let port): loc("недопустимый порт") + " \(port)"
        case RemoteDisplayError.listenerFailed(let reason): loc("не удалось открыть порт (возможно, занят):") + " \(reason)"
        default: "\(error)"
        }
    }

    static func loadPageHTML(bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: "RemoteDisplayPage", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8)
        else { return RemoteDisplayPage.fallbackHTML }
        return html
    }
}

enum LocalNetworkAddresses {
    static func ipv4() -> [String] {
        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: host)
                if !addresses.contains(text) { addresses.append(text) }
            }
        }
        return addresses.sorted { lhs, rhs in
            let lhsPrivate = lhs.hasPrefix("192.168.") || lhs.hasPrefix("10.")
            let rhsPrivate = rhs.hasPrefix("192.168.") || rhs.hasPrefix("10.")
            if lhsPrivate != rhsPrivate { return lhsPrivate }
            return lhs < rhs
        }
    }
}
