import CompanionProtocol
import Foundation
import Network

public enum CompanionPanelURL {
    public static func lanAddresses(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.filter { address in
            guard let literal = IPAddressLiteral(address), literal.isPrivateRFC1918 else { return false }
            return seen.insert(address).inserted
        }
    }

    public static func urls(addresses: [String], port: UInt16) -> [String] {
        lanAddresses(addresses).map { "http://\($0):\(port)/" }
    }
}

public protocol CompanionNetworkMonitoring: Sendable {
    func addressChanges() -> AsyncStream<[String]>
}

public final class CompanionNetworkMonitor: CompanionNetworkMonitoring {
    private let addresses: @Sendable () -> [String]

    public init(addresses: @escaping @Sendable () -> [String] = LocalInterfaceAddresses.current) {
        self.addresses = addresses
    }

    public func addressChanges() -> AsyncStream<[String]> {
        let addresses = self.addresses
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            let last = LockedValue<[String]?>(nil)
            monitor.pathUpdateHandler = { _ in
                let current = CompanionPanelURL.lanAddresses(addresses())
                let changed = last.update { previous -> Bool in
                    guard previous != current else { return false }
                    previous = current
                    return true
                }
                if changed { continuation.yield(current) }
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.local.UserAgent057.companion.path"))
        }
    }
}
