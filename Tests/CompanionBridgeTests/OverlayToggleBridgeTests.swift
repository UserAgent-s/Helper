import CompanionProtocol
import Domain
import Foundation
import Testing
@testable import CompanionBridge

@Suite struct OverlayToggleBridgeTests {
    @Test func disablingOverlayUpdatesSnapshotAndKeepsStreamingToWeb() async throws {
        let bridge = CompanionBridge(control: FakeDomainControl())
        let feeds = ManualFeeds()
        let sink = EventSink()
        await bridge.setPublisher { event in await sink.append(event) }
        await bridge.start(feeds: feeds.feeds)
        #expect(await bridge.snapshot().overlayEnabled)

        await bridge.setOverlayEnabled(false)
        await waitUntil { await sink.types.contains("state.snapshot") }
        #expect(await bridge.snapshot().overlayEnabled == false)

        feeds.answers.yield(AnswerStreamUpdate(responseID: "r1", trigger: .manual, event: .streaming(text: "Ответ")))
        feeds.answers.yield(AnswerStreamUpdate(responseID: "r1", trigger: .manual, event: .completed(finalText: "Ответ готов")))
        await waitUntil { await sink.types.contains("answer.done") }
        let types = await sink.types
        #expect(types.contains("answer.started"))
        #expect(types.contains("answer.delta"))
        #expect(await sink.texts.joined().contains("Ответ"))

        let before = await sink.types.count
        await bridge.setOverlayEnabled(false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await sink.types.count == before)
        await bridge.shutdown()
    }
}
