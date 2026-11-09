import Foundation
import Testing
@testable import CompanionProtocol

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

struct SequenceRandom: CompanionRandomSource {
    let values: [[UInt8]]
    let counter = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var index = 0
        func next() -> Int { lock.withLock { defer { index += 1 }; return index } }
    }

    func bytes(count: Int) -> [UInt8] {
        let value = values[counter.next() % values.count]
        return Array((value + [UInt8](repeating: 0, count: count)).prefix(count))
    }
}

@Suite struct PairingStoreTests {
    private func makeStore(_ clock: TestClock = TestClock(), storage: InMemoryPairedDeviceStore = InMemoryPairedDeviceStore()) -> PairingStore {
        PairingStore(storage: storage, now: { clock.now })
    }

    @Test func qrCodeIs128BitBase64URL() async {
        let code = await makeStore().issueCode(.qr128)
        #expect(code.value.count == 22)
        #expect(code.value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func numericCodeIsSixDigits() async {
        let code = await makeStore().issueCode(.numeric6)
        #expect(code.value.count == 6)
        #expect(code.value.allSatisfy { $0.isNumber })
    }

    @Test func numericCodeRejectsBiasedSamplesAndPadsZeros() {
        let random = SequenceRandom(values: [[0xff, 0xff, 0xff, 0xff], [0, 0, 0, 42]])
        #expect(CompanionSecrets.numericCode(digits: 6, random: random) == "000042")
    }

    @Test func redeemIssues256BitTokenAndStoresOnlyHash() async throws {
        let storage = InMemoryPairedDeviceStore()
        let store = makeStore(storage: storage)
        let code = await store.issueCode(.qr128)
        let grant = try await store.redeem(code: code.value, deviceName: "MacBook M1")
        #expect(grant.deviceToken.count == 43)
        let stored = await storage.loadAll()
        #expect(stored.count == 1)
        #expect(stored[0].tokenHash == CompanionSecrets.sha256Hex(grant.deviceToken))
        #expect(stored[0].tokenHash != grant.deviceToken)
        #expect(stored[0].name == "MacBook M1")
        let device = try await store.authenticate(token: grant.deviceToken)
        #expect(device?.deviceId == grant.deviceId)
        #expect(device?.lastSeenAt != nil)
    }

    @Test func reusedCodeIsRejected() async throws {
        let store = makeStore()
        let code = await store.issueCode(.qr128)
        _ = try await store.redeem(code: code.value, deviceName: "A")
        await #expect(throws: PairingError.invalidCode) {
            try await store.redeem(code: code.value, deviceName: "B")
        }
    }

    @Test func expiredCodeIsRejected() async throws {
        let clock = TestClock()
        let store = makeStore(clock)
        let code = await store.issueCode(.numeric6)
        clock.advance(PairingStore.codeLifetime + 1)
        #expect(await store.activeCode(.numeric6) == nil)
        await #expect(throws: PairingError.expired) {
            try await store.redeem(code: code.value, deviceName: "A")
        }
        await #expect(throws: PairingError.invalidCode) {
            try await store.redeem(code: code.value, deviceName: "A")
        }
    }

    @Test func codeStillValidJustBeforeExpiry() async throws {
        let clock = TestClock()
        let store = makeStore(clock)
        let code = await store.issueCode(.qr128)
        clock.advance(PairingStore.codeLifetime - 1)
        _ = try await store.redeem(code: code.value, deviceName: "A")
    }

    @Test func numericCodeBurnsAfterFiveWrongAttempts() async throws {
        let store = makeStore()
        let code = await store.issueCode(.numeric6)
        let wrong = code.value == "000000" ? "000001" : "000000"
        for _ in 0..<4 {
            await #expect(throws: PairingError.invalidCode) { try await store.redeem(code: wrong, deviceName: "A") }
        }
        await #expect(throws: PairingError.attemptsExhausted) { try await store.redeem(code: wrong, deviceName: "A") }
        await #expect(throws: PairingError.invalidCode) { try await store.redeem(code: code.value, deviceName: "A") }
    }

    @Test func attemptLimitsAreSeparatePerKind() async throws {
        let store = makeStore()
        let qr = await store.issueCode(.qr128)
        let numeric = await store.issueCode(.numeric6)
        for _ in 0..<10 {
            await #expect(throws: PairingError.invalidCode) { try await store.redeem(code: "wrong-qr-code-value-xx", deviceName: "A") }
        }
        let wrong = numeric.value == "000000" ? "000001" : "000000"
        await #expect(throws: PairingError.invalidCode) { try await store.redeem(code: wrong, deviceName: "A") }
        _ = try await store.redeem(code: numeric.value, deviceName: "Native")
        _ = try await store.redeem(code: qr.value, deviceName: "Browser")
        #expect(try await store.pairedDevices().count == 2)
    }

    @Test func reissuingReplacesPreviousCode() async throws {
        let store = makeStore()
        let first = await store.issueCode(.qr128)
        let second = await store.issueCode(.qr128)
        await #expect(throws: PairingError.invalidCode) { try await store.redeem(code: first.value, deviceName: "A") }
        _ = try await store.redeem(code: second.value, deviceName: "A")
    }

    @Test func emptyDeviceNameIsRejectedWithoutConsumingCode() async throws {
        let store = makeStore()
        let code = await store.issueCode(.qr128)
        await #expect(throws: PairingError.invalidDeviceName) { try await store.redeem(code: code.value, deviceName: "  ") }
        _ = try await store.redeem(code: code.value, deviceName: "A")
    }

    @Test func unknownTokenFailsAuthentication() async throws {
        let store = makeStore()
        #expect(try await store.authenticate(token: "nope") == nil)
        #expect(try await store.authenticate(token: "") == nil)
    }

    @Test func revokeRemovesDeviceAndEmitsRevocation() async throws {
        let storage = InMemoryPairedDeviceStore()
        let store = makeStore(storage: storage)
        let a = try await store.redeem(code: await store.issueCode(.qr128).value, deviceName: "A")
        let b = try await store.redeem(code: await store.issueCode(.qr128).value, deviceName: "B")
        var iterator = store.revocations.makeAsyncIterator()

        try await store.revoke(deviceId: a.deviceId)
        #expect(await iterator.next() == .device(a.deviceId))
        #expect(try await store.authenticate(token: a.deviceToken) == nil)
        #expect(try await store.authenticate(token: b.deviceToken)?.deviceId == b.deviceId)
        #expect(await storage.loadAll().map(\.deviceId) == [b.deviceId])

        try await store.revokeAll()
        #expect(await iterator.next() == .all)
        #expect(try await store.authenticate(token: b.deviceToken) == nil)
        #expect(await storage.loadAll().isEmpty)
    }

    @Test func revokeAllAlsoCancelsOutstandingCodes() async throws {
        let store = makeStore()
        let code = await store.issueCode(.qr128)
        try await store.revokeAll()
        await #expect(throws: PairingError.invalidCode) { try await store.redeem(code: code.value, deviceName: "A") }
    }

    @Test func devicesLoadFromStorageOnFirstUse() async throws {
        let token = "persisted-token"
        let storage = InMemoryPairedDeviceStore([
            PairedDevice(deviceId: "d1", name: "Old", tokenHash: CompanionSecrets.sha256Hex(token), createdAt: Date(timeIntervalSince1970: 1)),
        ])
        let store = makeStore(storage: storage)
        #expect(try await store.authenticate(token: token)?.deviceId == "d1")
    }

    @Test func constantTimeEqualsHandlesLengthMismatch() {
        #expect(CompanionSecrets.constantTimeEquals("abc", "abc"))
        #expect(!CompanionSecrets.constantTimeEquals("abc", "abd"))
        #expect(!CompanionSecrets.constantTimeEquals("abc", "abcd"))
        #expect(!CompanionSecrets.constantTimeEquals("", "a"))
    }

    @Test func classifyRoutesSixDigitsToNumeric() {
        #expect(PairingCodeKind.classify("123456") == .numeric6)
        #expect(PairingCodeKind.classify("12345") == .qr128)
        #expect(PairingCodeKind.classify("١٢٣٤٥٦") == .qr128)
    }
}
