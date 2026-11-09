import Foundation

public enum PairingError: Error, Sendable, Equatable {
    case invalidCode
    case expired
    case attemptsExhausted
    case invalidDeviceName

    public var code: String {
        switch self {
        case .invalidCode: "pair_invalid_code"
        case .expired: "pair_code_expired"
        case .attemptsExhausted: "pair_attempts_exhausted"
        case .invalidDeviceName: "invalid_argument"
        }
    }
}

public struct PairingGrant: Sendable, Equatable {
    public let deviceId: String
    public let deviceToken: String
}

public enum PairingRevocation: Sendable, Equatable {
    case device(String)
    case all
}

public actor PairingStore {
    private struct ActiveCode {
        let code: PairingCode
        var failures = 0
    }

    public static let codeLifetime: TimeInterval = 300

    private let storage: any PairedDeviceStoring
    private let random: any CompanionRandomSource
    private let now: @Sendable () -> Date
    private let codeLifetime: TimeInterval

    private var codes: [PairingCodeKind: ActiveCode] = [:]
    private var devices: [String: PairedDevice] = [:]
    private var loaded = false

    public nonisolated let revocations: AsyncStream<PairingRevocation>
    private let revocationContinuation: AsyncStream<PairingRevocation>.Continuation

    public init(
        storage: any PairedDeviceStoring,
        random: any CompanionRandomSource = SystemCompanionRandom(),
        codeLifetime: TimeInterval = PairingStore.codeLifetime,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storage = storage
        self.random = random
        self.codeLifetime = codeLifetime
        self.now = now
        (revocations, revocationContinuation) = AsyncStream<PairingRevocation>.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    public func issueCode(_ kind: PairingCodeKind) -> PairingCode {
        let value: String
        switch kind {
        case .qr128: value = CompanionSecrets.base64URL(random.bytes(count: CompanionSecrets.qrCodeByteCount))
        case .numeric6: value = CompanionSecrets.numericCode(digits: 6, random: random)
        }
        let code = PairingCode(kind: kind, value: value, expiresAt: now().addingTimeInterval(codeLifetime))
        codes[kind] = ActiveCode(code: code)
        return code
    }

    public func cancelCode(_ kind: PairingCodeKind) {
        codes[kind] = nil
    }

    public func activeCode(_ kind: PairingCodeKind) -> PairingCode? {
        guard let active = codes[kind], active.code.expiresAt > now() else { return nil }
        return active.code
    }

    public func redeem(code input: String, deviceName: String) async throws -> PairingGrant {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= CompanionLimits.maxDeviceNameLength else {
            throw PairingError.invalidDeviceName
        }
        let kind = PairingCodeKind.classify(input)
        guard var active = codes[kind] else { throw PairingError.invalidCode }
        guard CompanionSecrets.constantTimeEquals(active.code.value, input) else {
            active.failures += 1
            if active.failures >= kind.maxAttempts {
                codes[kind] = nil
                throw PairingError.attemptsExhausted
            }
            codes[kind] = active
            throw PairingError.invalidCode
        }
        codes[kind] = nil
        guard active.code.expiresAt > now() else { throw PairingError.expired }

        try await ensureLoaded()
        let token = CompanionSecrets.base64URL(random.bytes(count: CompanionSecrets.tokenByteCount))
        let device = PairedDevice(
            deviceId: UUID().uuidString.lowercased(),
            name: name,
            tokenHash: CompanionSecrets.sha256Hex(token),
            createdAt: now()
        )
        try await storage.insert(device)
        devices[device.deviceId] = device
        return PairingGrant(deviceId: device.deviceId, deviceToken: token)
    }

    public func authenticate(token: String) async throws -> PairedDevice? {
        guard !token.isEmpty, token.utf16.count <= CompanionLimits.maxTokenLength else { return nil }
        try await ensureLoaded()
        let hash = CompanionSecrets.sha256Hex(token)
        var match: PairedDevice?
        for device in devices.values where CompanionSecrets.constantTimeEquals(device.tokenHash, hash) {
            match = device
        }
        guard var device = match else { return nil }
        let seen = now()
        device.lastSeenAt = seen
        devices[device.deviceId] = device
        try await storage.updateLastSeen(deviceId: device.deviceId, at: seen)
        return device
    }

    public func pairedDevices() async throws -> [PairedDevice] {
        try await ensureLoaded()
        return devices.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func revoke(deviceId: String) async throws {
        try await ensureLoaded()
        try await storage.delete(deviceId: deviceId)
        devices[deviceId] = nil
        revocationContinuation.yield(.device(deviceId))
    }

    public func revokeAll() async throws {
        try await ensureLoaded()
        try await storage.deleteAll()
        devices.removeAll()
        codes.removeAll()
        revocationContinuation.yield(.all)
    }

    private func ensureLoaded() async throws {
        guard !loaded else { return }
        for device in try await storage.loadAll() {
            devices[device.deviceId] = device
        }
        loaded = true
    }
}
