import CompanionProtocol
import Foundation

public enum CompanionCloseCode {
    public static let goingAway: UInt16 = 1001
    public static let protocolError: UInt16 = 1002
    public static let unsupportedData: UInt16 = 1003
    public static let messageTooBig: UInt16 = 1009
    public static let unauthorized: UInt16 = 4401
    public static let forbidden: UInt16 = 4403
    public static let helloTimeout: UInt16 = 4408
    public static let tooManyClients: UInt16 = 4409
    public static let unsupportedVersion: UInt16 = 4426
    public static let throttled: UInt16 = 4429
}

public struct CompanionOutbound: Sendable {
    public let send: @Sendable (String) -> Void
    public let close: @Sendable (UInt16, String) -> Void

    public init(send: @escaping @Sendable (String) -> Void, close: @escaping @Sendable (UInt16, String) -> Void) {
        self.send = send
        self.close = close
    }
}

public enum CompanionBindAddress: Sendable, Equatable {
    case anyInterface
    case loopback
}

public struct CompanionServerConfiguration: Sendable, Equatable {
    public static let defaultPort: UInt16 = 47057

    public var preferredPort: UInt16
    public var bind: CompanionBindAddress
    public var pingInterval: Duration
    public var maxInboundMessageBytes: Int

    public init(
        preferredPort: UInt16 = CompanionServerConfiguration.defaultPort,
        bind: CompanionBindAddress = .anyInterface,
        pingInterval: Duration = .seconds(10),
        maxInboundMessageBytes: Int = CompanionLimits.maxInboundFrameBytes
    ) {
        self.preferredPort = preferredPort
        self.bind = bind
        self.pingInterval = pingInterval
        self.maxInboundMessageBytes = maxInboundMessageBytes
    }
}

public protocol CompanionTransport: Sendable {
    func start(configuration: CompanionServerConfiguration, hub: CompanionHub) async throws -> UInt16
    func stop() async
}

public enum CompanionCommandOutcome: Sendable, Equatable {
    case ok
    case rejected(code: String, message: String? = nil)
}

public protocol CompanionHubDelegate: Sendable {
    func snapshot() async -> StateSnapshot
    func perform(_ action: ClientCommand.Action, deviceId: String) async -> CompanionCommandOutcome
    func exportDocument(sessionId: String) async -> CompanionExportOutcome
}

extension CompanionHubDelegate {
    public func exportDocument(sessionId: String) async -> CompanionExportOutcome {
        .rejected(code: "not_available")
    }
}
