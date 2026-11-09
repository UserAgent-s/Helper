import Foundation
import Testing
@testable import CompanionProtocol

@Suite struct PairingEventsTests {
    @Test func everySubscriberSeesRedeemedDeviceAndCancelledSubscribersAreRemoved() async throws {
        let store = PairingStore(storage: InMemoryPairedDeviceStore())
        let first = await store.pairingEvents()
        let second = await store.pairingEvents()
        #expect(await store.pairingObserverCount == 2)
        let code = await store.issueCode(.numeric6)
        let grant = try await store.redeem(code: code.value, deviceName: "Phone")
        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()
        #expect(await firstIterator.next()?.deviceId == grant.deviceId)
        #expect(await secondIterator.next()?.name == "Phone")

        let task = Task {
            for await _ in await store.pairingEvents() {}
        }
        for _ in 0..<200 where await store.pairingObserverCount < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await store.pairingObserverCount == 3)
        task.cancel()
        for _ in 0..<200 where await store.pairingObserverCount > 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await store.pairingObserverCount == 2)
    }

    @Test func failedRedeemDoesNotEmit() async throws {
        let store = PairingStore(storage: InMemoryPairedDeviceStore())
        let events = await store.pairingEvents()
        _ = await store.issueCode(.numeric6)
        await #expect(throws: PairingError.self) { try await store.redeem(code: "000000x", deviceName: "X") }
        let probe = Task { () -> PairedDevice? in
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(50))
        probe.cancel()
        #expect(await probe.value == nil)
    }
}
