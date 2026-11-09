import Darwin
import Foundation

public enum IPAddressLiteral: Sendable, Hashable {
    case v4([UInt8])
    case v6([UInt8])

    public init?(_ text: String) {
        var literal = text
        if literal.hasPrefix("["), literal.hasSuffix("]") {
            literal = String(literal.dropFirst().dropLast())
        }
        if let zone = literal.firstIndex(of: "%") {
            literal = String(literal[..<zone])
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            self = .v4(withUnsafeBytes(of: v4.s_addr) { Array($0) })
            return
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, literal, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            self = .v4(Array(bytes[12..<16]))
        } else {
            self = .v6(bytes)
        }
    }

    public var isLoopback: Bool {
        switch self {
        case .v4(let b): b[0] == 127
        case .v6(let b): b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
        }
    }

    public var isLinkLocal: Bool {
        switch self {
        case .v4(let b): b[0] == 169 && b[1] == 254
        case .v6(let b): b[0] == 0xfe && (b[1] & 0xc0) == 0x80
        }
    }

    public var isPrivateRFC1918: Bool {
        guard case .v4(let b) = self else { return false }
        return b[0] == 10 || (b[0] == 172 && (b[1] & 0xf0) == 16) || (b[0] == 192 && b[1] == 168)
    }

    public var isAllowedCompanionSource: Bool {
        isLoopback || isLinkLocal || isPrivateRFC1918
    }
}

public enum RequestRejection: String, Sendable, Equatable {
    case sourceNotLocal = "source_not_local"
    case hostMismatch = "host_mismatch"
    case originMismatch = "origin_mismatch"
    case throttled
}

public struct RequestGuard: Sendable {
    public let port: Int

    public init(port: Int) {
        self.port = port
    }

    public func evaluate(remoteAddress: String, host: String?, origin: String?, serverAddresses: [String]) -> RequestRejection? {
        guard let remote = IPAddressLiteral(remoteAddress), remote.isAllowedCompanionSource else {
            return .sourceNotLocal
        }
        guard let host, let authority = Self.splitAuthority(host), authority.port == port else {
            return .hostMismatch
        }
        if let literal = IPAddressLiteral(authority.host) {
            let served = Set(serverAddresses.compactMap(IPAddressLiteral.init))
            guard served.contains(literal) || (literal.isLoopback && remote.isLoopback) else { return .hostMismatch }
        } else {
            guard authority.host.lowercased() == "localhost", remote.isLoopback else { return .hostMismatch }
        }
        if let origin {
            guard origin.lowercased() == "http://" + host.lowercased() else { return .originMismatch }
        }
        return nil
    }

    static func splitAuthority(_ value: String) -> (host: String, port: Int)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let hostPart = String(trimmed[trimmed.startIndex...close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (hostPart, port)
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let port = Int(parts[1]) else { return nil }
        return (String(parts[0]), port)
    }
}

public struct FailureThrottle: Sendable {
    public static let freeFailures = 5
    public static let maxDelay: TimeInterval = 60
    public static let forgetAfter: TimeInterval = 900

    private struct Entry: Sendable {
        var failures: Int
        var lastFailure: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func retryDelay(for key: String, now: Date) -> TimeInterval {
        guard let entry = entries[key], now.timeIntervalSince(entry.lastFailure) < Self.forgetAfter else { return 0 }
        let delay = Self.delay(afterFailures: entry.failures)
        return max(0, entry.lastFailure.addingTimeInterval(delay).timeIntervalSince(now))
    }

    public mutating func recordFailure(for key: String, now: Date) {
        var entry = entries[key] ?? Entry(failures: 0, lastFailure: now)
        if now.timeIntervalSince(entry.lastFailure) >= Self.forgetAfter {
            entry.failures = 0
        }
        entry.failures += 1
        entry.lastFailure = now
        entries[key] = entry
        entries = entries.filter { now.timeIntervalSince($0.value.lastFailure) < Self.forgetAfter }
    }

    public mutating func recordSuccess(for key: String) {
        entries[key] = nil
    }

    public func failureCount(for key: String) -> Int {
        entries[key]?.failures ?? 0
    }

    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures >= freeFailures else { return 0 }
        return min(maxDelay, pow(2, Double(failures - freeFailures)))
    }
}
