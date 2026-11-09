import Domain
import Foundation
import Testing
@testable import RealtimeClient

private func createdItems(_ transport: FakeRealtimeWebSocketTransport) -> [ConversationItemPayload] {
    transport.sentEvents.compactMap { if case .conversationItemCreate(let payload) = $0 { payload } else { nil } }
}

private func deleted(_ transport: FakeRealtimeWebSocketTransport) -> [String] {
    transport.sentEvents.compactMap { if case .conversationItemDelete(let id) = $0 { id } else { nil } }
}

private func responseCreates(_ transport: FakeRealtimeWebSocketTransport) -> Int {
    transport.sentEvents.filter { if case .responseCreate = $0 { true } else { false } }.count
}

@Suite struct InjectedContextTests {
    private func makeClient(clock: TestClock = TestClock(), sweepInterval: Duration = .seconds(60)) -> (OpenAIRealtimeAnswerClient, FakeRealtimeWebSocketTransport) {
        let transport = FakeRealtimeWebSocketTransport()
        let client = OpenAIRealtimeAnswerClient(
            transport: transport,
            credentialProviding: FakeCredentialProviding(),
            latencyRecording: RecordingLatencyRecorder(),
            reconnectBaseDelay: .milliseconds(10),
            maxReconnectAttempts: 1,
            sweepInterval: sweepInterval,
            now: { clock.now }
        )
        return (client, transport)
    }

    @Test func meRemarkIsUserItemWithTagAndNeverCreatesResponse() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        try await client.injectContext(.me("  Я пять лет писал платёжный сервис на Kafka  "))
        try await Task.sleep(for: .milliseconds(20))
        let item = try #require(createdItems(transport).first)
        #expect(item.role == .user)
        #expect(item.id.hasPrefix("ctx_"))
        #expect(item.text == "[Я]: Я пять лет писал платёжный сервис на Kafka")
        #expect(responseCreates(transport) == 0)
        await client.stop()
    }

    @Test func screenTextCarriesApplicationHeader() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        try await client.injectContext(.screen(application: "Google Chrome", text: "Реализуйте LRU-кэш"))
        try await client.injectContext(.screen(application: nil, text: "func get(_ key: Int) -> Int"))
        try await client.injectContext(.me("   "))
        let items = createdItems(transport)
        #expect(items.map(\.role) == [.user, .user])
        #expect(items.map(\.text) == ["[Экран: Google Chrome]\nРеализуйте LRU-кэш", "[Экран]\nfunc get(_ key: Int) -> Int"])
        #expect(responseCreates(transport) == 0)
        await client.stop()
    }

    @Test func injectedContextPlusAnswerNowGivesExactlyOneResponseCreate() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        await #expect(throws: RealtimeClientError.noContext) { try await client.forceResponse() }
        try await client.injectContext(.me("Я уже рассказал про шардирование"))
        try await client.injectContext(.screen(application: "Xcode", text: "fatal error: index out of range"))
        try await client.forceResponse()
        try await client.forceResponse()
        try await Task.sleep(for: .milliseconds(20))
        #expect(responseCreates(transport) == 1)
        await client.stop()
    }

    @Test func injectedItemsAreDeletedOnlyAfterCompletedResponse() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        try await client.injectContext(.me("Контекст владельца"))
        let ctxID = try #require(createdItems(transport).first?.id)

        transport.emit(.inputAudioBufferCommitted(itemID: "u1", previousItemID: nil))
        transport.emit(.responseCreated(responseID: "r1"))
        transport.emit(.outputTextDelta(responseID: "r1", itemID: "o1", delta: "Ответ"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!deleted(transport).contains(ctxID))

        transport.emit(.outputTextDone(responseID: "r1", itemID: "o1", text: "Ответ"))
        transport.emit(.responseDone(responseID: "r1", status: "completed", outputItemIDs: ["o1"]))
        await waitUntil { deleted(transport).contains(ctxID) }
        #expect(Set(deleted(transport)).isSuperset(of: [ctxID, "u1", "o1"]))
        await client.stop()
    }

    @Test func injectedItemsAreEvictedByMaxAgeButNotDuringStream() async throws {
        let clock = TestClock()
        let (client, transport) = makeClient(clock: clock, sweepInterval: .milliseconds(10))
        try await client.start(instructions: "test")
        try await client.injectContext(.me("Старая реплика"))
        let oldID = try #require(createdItems(transport).first?.id)

        transport.emit(.responseCreated(responseID: "r1"))
        transport.emit(.outputTextDelta(responseID: "r1", itemID: "o1", delta: "Идёт ответ"))
        try await Task.sleep(for: .milliseconds(20))
        clock.advance(by: 301)
        try await client.injectContext(.screen(application: nil, text: "Новый текст"))
        try await Task.sleep(for: .milliseconds(40))
        #expect(!deleted(transport).contains(oldID))

        transport.emit(.responseDone(responseID: "r1", status: "cancelled", outputItemIDs: ["o1"]))
        await waitUntil { deleted(transport).contains(oldID) }
        #expect(deleted(transport).contains(oldID))
        let newID = try #require(createdItems(transport).last?.id)
        #expect(!deleted(transport).contains(newID))
        await client.stop()
    }

    @Test func injectingAfterMaxAgeEvictsOldItemsWhenIdle() async throws {
        let clock = TestClock()
        let (client, transport) = makeClient(clock: clock)
        try await client.start(instructions: "test")
        try await client.injectContext(.me("Первая"))
        let firstID = try #require(createdItems(transport).first?.id)
        clock.advance(by: 301)
        try await client.injectContext(.me("Вторая"))
        #expect(deleted(transport) == [firstID])
        await client.stop()
    }

    @Test func instructionsTellModelNotToAnswerOwnerRemarks() {
        let system = RealtimeInstructions.system(for: .standard)
        #expect(system.contains("`[Я]:`"))
        #expect(system.contains("never repeat or paraphrase what the user already said"))
        #expect(system.contains("`[Экран`"))
        #expect(RealtimeInstructions.version == 6)
    }
}
