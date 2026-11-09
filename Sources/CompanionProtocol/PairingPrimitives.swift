import CryptoKit
import Foundation
import Security

public protocol CompanionRandomSource: Sendable {
    func bytes(count: Int) -> [UInt8]
}

public struct SystemCompanionRandom: CompanionRandomSource {
    public init() {}

    public func bytes(count: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return buffer
    }
}

public enum CompanionSecrets {
    public static let tokenByteCount = 32
    public static let qrCodeByteCount = 16

    public static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt64(left.count ^ right.count)
        let length = max(left.count, right.count)
        for index in 0..<length {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= UInt64(a ^ b)
        }
        return difference == 0
    }

    public static func numericCode(digits: Int, random: any CompanionRandomSource) -> String {
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let limit = UInt32.max - (UInt32.max % modulus)
        while true {
            let raw = random.bytes(count: 4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if raw < limit {
                let value = String(raw % modulus)
                return String(repeating: "0", count: digits - value.count) + value
            }
        }
    }
}

public enum PairingCodeKind: String, Sendable, Codable, CaseIterable {
    case qr128
    case numeric6

    public var maxAttempts: Int {
        switch self {
        case .qr128: 20
        case .numeric6: 5
        }
    }

    static func classify(_ code: String) -> PairingCodeKind {
        code.utf8.count == 6 && code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) ? .numeric6 : .qr128
    }
}

public struct PairingCode: Sendable, Equatable {
    public let kind: PairingCodeKind
    public let value: String
    public let expiresAt: Date
}

public struct PairedDevice: Sendable, Equatable, Codable {
    public let deviceId: String
    public var name: String
    public let tokenHash: String
    public let createdAt: Date
    public var lastSeenAt: Date?

    public init(deviceId: String, name: String, tokenHash: String, createdAt: Date, lastSeenAt: Date? = nil) {
        self.deviceId = deviceId
        self.name = name
        self.tokenHash = tokenHash
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

public protocol PairedDeviceStoring: Sendable {
    func loadAll() async throws -> [PairedDevice]
    func insert(_ device: PairedDevice) async throws
    func updateLastSeen(deviceId: String, at date: Date) async throws
    func delete(deviceId: String) async throws
    func deleteAll() async throws
}

public actor InMemoryPairedDeviceStore: PairedDeviceStoring {
    private var devices: [String: PairedDevice] = [:]

    public init(_ initial: [PairedDevice] = []) {
        for device in initial { devices[device.deviceId] = device }
    }

    public func loadAll() -> [PairedDevice] {
        devices.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func insert(_ device: PairedDevice) {
        devices[device.deviceId] = device
    }

    public func updateLastSeen(deviceId: String, at date: Date) {
        devices[deviceId]?.lastSeenAt = date
    }

    public func delete(deviceId: String) {
        devices[deviceId] = nil
    }

    public func deleteAll() {
        devices.removeAll()
    }
}
