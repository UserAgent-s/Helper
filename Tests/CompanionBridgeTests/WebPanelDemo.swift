import CompanionProtocol
import CompanionServer
import Domain
import Foundation
import Testing
@testable import CompanionBridge

@Suite struct WebPanelDemo {
    static let enabled = ProcessInfo.processInfo.environment["UA057_WEB_DEMO"] == "1"

    @Test(.enabled(if: WebPanelDemo.enabled), .timeLimit(.minutes(30)))
    func serveDemoPanelOnLAN() async throws {
        let environment = ProcessInfo.processInfo.environment
        let seconds = Double(environment["UA057_WEB_DEMO_SECONDS"] ?? "180") ?? 180
        let control = FakeDomainControl()
        let bridge = CompanionBridge(control: control)
        let feeds = ManualFeeds()
        await bridge.start(feeds: feeds.feeds)
        let pairing = PairingStore(storage: InMemoryPairedDeviceStore())
        let code = await pairing.issueCode(.numeric6)
        let service = CompanionService(
            pairing: pairing,
            bridge: bridge,
            configuration: CompanionServerConfiguration(preferredPort: 47057, bind: .anyInterface),
            serverVersion: "demo"
        )
        let port = try await service.start()
        let hosts = LocalInterfaceAddresses.current().filter { !$0.contains(":") }
        let urls = hosts.map { "http://\($0):\(port)/#pair=\(code.value)" }
        let summary = (["code \(code.value)"] + urls).joined(separator: "\n")
        print("WEB_DEMO\n\(summary)")
        if let path = environment["UA057_WEB_DEMO_OUT"] {
            try summary.write(toFile: path, atomically: true, encoding: .utf8)
        }

        feeds.mode.yield(ModeState(mode: .answers, phase: .active, startedAt: Date(), userFacingError: nil))
        feeds.notices.yield(.outputRouteChanged(.wiredHeadphones))
        let deadline = Date().addingTimeInterval(seconds)
        var round = 0
        while Date() < deadline {
            round += 1
            let item = "q\(round)"
            var heard = ""
            for word in ["Расскажите,", "как", "вы", "снижали", "риски", "в", "проекте", "номер", "\(round)?"] {
                heard += (heard.isEmpty ? "" : " ") + word
                feeds.transcripts.yield(TranscriptEvent(speaker: .them, itemID: item, text: heard, isFinal: false))
                feeds.levels.yield(AudioLevel(kind: .systemAudio, rmsDBFS: Float.random(in: -40 ... -12), peakDBFS: -6, at: Date()))
                try await Task.sleep(for: .milliseconds(120))
            }
            feeds.transcripts.yield(TranscriptEvent(speaker: .them, itemID: item, text: heard, language: "ru", isFinal: true))
            let answer = "Коротко: начал с карты рисков.\n1. Выписал зависимости и владельцев.\n2. Ввёл еженедельный обзор с метриками.\n3. Для критичных пунктов заранее готовил запасной план ⟦WAIT_FOR_QUESTION⟧"
            var accumulated = ""
            for character in answer {
                accumulated.append(character)
                if character == " " || character == "\n" {
                    feeds.answers.yield(AnswerStreamUpdate(responseID: "demo-\(round)", trigger: .automatic, event: .streaming(text: accumulated)))
                    feeds.levels.yield(AudioLevel(kind: .microphone, rmsDBFS: Float.random(in: -55 ... -35), peakDBFS: -20, at: Date()))
                    try await Task.sleep(for: .milliseconds(60))
                }
            }
            feeds.answers.yield(AnswerStreamUpdate(responseID: "demo-\(round)", trigger: .automatic, event: .completed(finalText: answer)))
            feeds.transcripts.yield(TranscriptEvent(speaker: .me, itemID: "m\(round)", text: "Да, расскажу по шагам.", language: "ru", isFinal: true))
            try await Task.sleep(for: .seconds(4))
        }
        await service.stop()
        await bridge.shutdown()
    }
}
