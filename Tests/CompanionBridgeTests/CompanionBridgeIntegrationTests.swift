import CompanionProtocol
import CompanionServer
import Domain
import Foundation
import Testing
@testable import CompanionBridge
@testable import RealtimeClient

@Suite(.serialized) struct CompanionBridgeIntegrationTests {
    struct Fixture {
        let transport: FakeRealtimeWebSocketTransport
        let coordinator: ModeCoordinator
        let answers: AnswersModeController
        let bridge: CompanionBridge
        let service: CompanionService
        let socket: TestSocket

        static func make() async throws -> Fixture {
            let transport = FakeRealtimeWebSocketTransport()
            let client = OpenAIRealtimeAnswerClient(
                transport: transport,
                credentialProviding: StaticCredential(),
                latencyRecording: NoLatency(),
                reconnectBaseDelay: .milliseconds(10),
                maxReconnectAttempts: 1
            )
            let captureHub = CaptureHub(system: FakeSystemAudioCapturing(), microphone: FakeMicrophoneCapturing())
            let trigger = ManualAnswerTrigger()
            let answers = AnswersModeController(captureHub: captureHub, realtime: client, answerTrigger: trigger, instructionsProvider: { "test" })
            let coordinator = ModeCoordinator(controllers: [.answers: answers])
            let bridge = CompanionBridge(control: LiveCompanionDomain(modeCoordinator: coordinator, answers: answers, trigger: trigger))
            await bridge.start(feeds: LiveCompanionDomain.feeds(modeCoordinator: coordinator, answers: answers, captureHub: captureHub))
            let pairing = PairingStore(storage: InMemoryPairedDeviceStore())
            let grant = try await pairing.redeem(code: await pairing.issueCode(.qr128).value, deviceName: "M1")
            let service = CompanionService(
                pairing: pairing,
                bridge: bridge,
                transport: FlyingFoxCompanionTransport(localAddresses: { [] }),
                configuration: CompanionServerConfiguration(preferredPort: 0, bind: .loopback),
                serverVersion: "test"
            )
            let port = try await service.start()
            let socket = TestSocket(port: port)
            try await socket.send(ClientCommand(cmdId: "h", action: .hello(.init(token: grant.deviceToken))))
            _ = try await socket.next { if case .helloOK = $0 { true } else { false } }
            _ = try await socket.next { if case .stateSnapshot = $0 { true } else { false } }
            return Fixture(transport: transport, coordinator: coordinator, answers: answers, bridge: bridge, service: service, socket: socket)
        }

        func command(_ cmdId: String, _ action: ClientCommand.Action) async throws -> ServerEvent.Ack {
            try await socket.send(ClientCommand(cmdId: cmdId, action: action))
            let envelope = try await socket.next { if case .ack(let ack) = $0 { ack.cmdId == cmdId } else { false } }
            guard case .ack(let ack) = envelope.event else { throw TimedOut() }
            return ack
        }

        func tearDown() async {
            socket.close()
            await service.stop()
            await coordinator.shutdown(timeout: .seconds(2))
            await bridge.shutdown()
        }
    }

    @Test func answerNowFromWebCreatesOneResponseAndDeltaArrivesBeforeDone() async throws {
        let fixture = try await Fixture.make()
        let ack = try await fixture.command("mode", .setMode(.init(mode: .answers)))
        #expect(ack.ok)
        await waitUntil { await fixture.bridge.snapshot().mode.phase == .active }
        #expect(await fixture.bridge.snapshot().mode == ModeInfo(mode: .answers, phase: .active, startedAt: await fixture.bridge.snapshot().mode.startedAt))

        fixture.transport.emit(.inputAudioBufferCommitted(itemID: "user-1", previousItemID: nil))
        try await Task.sleep(for: .milliseconds(20))
        #expect(try await fixture.command("a1", .answerNow).ok)
        #expect(try await fixture.command("a2", .answerNow).ok)
        await waitUntil { fixture.transport.responseCreateCount >= 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.transport.responseCreateCount == 1)

        fixture.transport.emit(.responseCreated(responseID: "manual-1", metadata: ["trigger": "manual"]))
        fixture.transport.emit(.outputTextDelta(responseID: "manual-1", itemID: "out-1", delta: "Короткий ответ."))
        let started = try await fixture.socket.next { if case .answerStarted = $0 { true } else { false } }
        guard case .answerStarted(let info) = started.event else { return }
        #expect(info.answerId == "manual-1")
        #expect(info.trigger == .manual)
        let delta = try await fixture.socket.next { if case .answerDelta = $0 { true } else { false } }
        guard case .answerDelta(let first) = delta.event else { return }
        #expect(first.text == "Короткий ответ.")

        fixture.transport.emit(.outputTextDone(responseID: "manual-1", itemID: "out-1", text: "Короткий ответ."))
        fixture.transport.emit(.responseDone(responseID: "manual-1", status: "completed", outputItemIDs: ["out-1"]))
        let done = try await fixture.socket.next { if case .answerDone = $0 { true } else { false } }
        #expect(done.seq > delta.seq)
        guard case .answerDone(let finished) = done.event else { return }
        #expect(finished.status == .completed)
        #expect(finished.length == "Короткий ответ.".utf16.count)

        await fixture.tearDown()
    }

    @Test func resetFromWebRejectedDuringStreamAndAcceptedAfter() async throws {
        let fixture = try await Fixture.make()
        #expect(try await fixture.command("mode", .setMode(.init(mode: .answers))).ok)
        fixture.transport.emit(.inputAudioBufferCommitted(itemID: "user-1", previousItemID: nil))
        fixture.transport.emit(.responseCreated(responseID: "auto-1", metadata: ["trigger": "automatic"]))
        fixture.transport.emit(.outputTextDelta(responseID: "auto-1", itemID: "out-1", delta: "Идёт ответ"))
        _ = try await fixture.socket.next { if case .answerDelta = $0 { true } else { false } }

        let rejected = try await fixture.command("r1", .resetContext)
        #expect(!rejected.ok)
        #expect(rejected.code == "answer_in_progress")

        fixture.transport.emit(.outputTextDone(responseID: "auto-1", itemID: "out-1", text: "Идёт ответ"))
        fixture.transport.emit(.responseDone(responseID: "auto-1", status: "completed", outputItemIDs: ["out-1"]))
        _ = try await fixture.socket.next { if case .answerDone = $0 { true } else { false } }
        await waitUntil { await !fixture.answers.isAnswerInFlight }
        #expect(try await fixture.command("r2", .resetContext).ok)

        let snapshot = await fixture.bridge.snapshot()
        #expect(snapshot.answer?.text == "Идёт ответ")
        #expect(snapshot.mode.mode == .answers)
        await fixture.tearDown()
    }

    @Test func serviceStopReleasesPortAndRestartWorks() async throws {
        let fixture = try await Fixture.make()
        #expect(await fixture.service.isRunning)
        await fixture.service.stop()
        #expect(await !fixture.service.isRunning)
        let port = try await fixture.service.start()
        #expect(port > 0)
        await fixture.tearDown()
    }
}
