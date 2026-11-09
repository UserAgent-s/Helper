import Domain
import Foundation
import Testing
@testable import RealtimeClient

protocol LiveResponderHarness: Sendable {
    var responder: any LiveResponder { get }
    func simulateUserSpeech() async
    func deliverManualAnswer(_ text: String) async
    func responseRequestCount() async -> Int
}

struct OpenAIHarness: LiveResponderHarness {
    let transport = FakeRealtimeWebSocketTransport()
    let responder: any LiveResponder
    private let counter = ItemCounter()

    init() {
        responder = OpenAIRealtimeAnswerClient(
            transport: transport,
            credentialProviding: FakeCredentialProviding(),
            latencyRecording: RecordingLatencyRecorder(),
            reconnectBaseDelay: .milliseconds(10),
            maxReconnectAttempts: 1
        )
    }

    func simulateUserSpeech() async {
        let id = await counter.next()
        transport.emit(.inputAudioBufferCommitted(itemID: "user-\(id)", previousItemID: nil))
        try? await Task.sleep(for: .milliseconds(10))
    }

    func deliverManualAnswer(_ text: String) async {
        transport.emit(.responseCreated(responseID: "manual-1", metadata: ["trigger": "manual"]))
        transport.emit(.outputTextDelta(responseID: "manual-1", itemID: "out-1", delta: text))
        transport.emit(.outputTextDone(responseID: "manual-1", itemID: "out-1", text: text))
        transport.emit(.responseDone(responseID: "manual-1", status: "completed", outputItemIDs: ["out-1"]))
        try? await Task.sleep(for: .milliseconds(20))
    }

    func responseRequestCount() async -> Int {
        transport.sentEvents.filter { if case .responseCreate = $0 { true } else { false } }.count
    }
}

actor ItemCounter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

actor ScriptedLiveResponder: LiveResponder {
    private let stream: AsyncStream<RealtimeAnswerEvent>
    private let continuation: AsyncStream<RealtimeAnswerEvent>.Continuation
    private var active = false
    private var contextItems = 0
    private var pendingManual = false
    private(set) var requestCount = 0

    init() {
        (stream, continuation) = AsyncStream<RealtimeAnswerEvent>.makeStream()
    }

    nonisolated var capabilities: ProviderCapabilities { [.textInjection, .manualResponse, .streamingText] }

    func start(instructions: String) async throws { active = true }

    func appendAudio(_ frame: PCMAudioFrame) async {}

    func userSpoke() { contextItems += 1 }

    nonisolated func events() -> AsyncStream<RealtimeAnswerEvent> { stream }

    func injectContext(_ context: InjectedContext) async throws {
        guard active else { throw RealtimeClientError.notConnected }
        contextItems += 1
    }

    func forceResponse() async throws {
        guard active else { throw RealtimeClientError.notConnected }
        guard contextItems > 0 else { throw RealtimeClientError.noContext }
        guard !pendingManual else { return }
        pendingManual = true
        requestCount += 1
    }

    func deliver(_ text: String) {
        guard pendingManual else { return }
        pendingManual = false
        contextItems = 0
        continuation.yield(.responseStarted(responseID: "manual-1", trigger: .manual))
        continuation.yield(.textDelta(responseID: "manual-1", text: text))
        continuation.yield(.completed(responseID: "manual-1"))
    }

    func resetContext() async {
        contextItems = 0
        pendingManual = false
    }

    func stop() async {
        active = false
        continuation.finish()
    }
}

struct ScriptedHarness: LiveResponderHarness {
    let scripted = ScriptedLiveResponder()
    var responder: any LiveResponder { scripted }

    func simulateUserSpeech() async { await scripted.userSpoke() }
    func deliverManualAnswer(_ text: String) async { await scripted.deliver(text) }
    func responseRequestCount() async -> Int { await scripted.requestCount }
}

enum HarnessKind: String, CaseIterable, CustomTestStringConvertible {
    case openAI, scripted

    var testDescription: String { rawValue }

    func make() -> any LiveResponderHarness {
        switch self {
        case .openAI: OpenAIHarness()
        case .scripted: ScriptedHarness()
        }
    }
}

final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [RealtimeAnswerEvent] = []

    func append(_ event: RealtimeAnswerEvent) {
        lock.lock(); collected.append(event); lock.unlock()
    }

    var events: [RealtimeAnswerEvent] {
        lock.lock(); defer { lock.unlock() }
        return collected
    }
}

@Suite struct LiveResponderContractTests {

    @Test(arguments: HarnessKind.allCases)
    func advertisesInjectionAndManualResponse(_ kind: HarnessKind) {
        let capabilities = kind.make().responder.capabilities
        #expect(capabilities.contains(.textInjection))
        #expect(capabilities.contains(.manualResponse))
    }

    @Test(arguments: HarnessKind.allCases)
    func answerNowWithoutContextIsRejected(_ kind: HarnessKind) async throws {
        let harness = kind.make()
        try await harness.responder.start(instructions: "test")
        await #expect(throws: RealtimeClientError.noContext) {
            try await harness.responder.forceResponse()
        }
        #expect(await harness.responseRequestCount() == 0)
        await harness.responder.stop()
    }

    @Test(arguments: HarnessKind.allCases)
    func answerNowRequestsExactlyOneResponseAndStreamsIt(_ kind: HarnessKind) async throws {
        let harness = kind.make()
        let collector = EventCollector()
        let listener = Task {
            for await event in harness.responder.events() { collector.append(event) }
        }
        try await harness.responder.start(instructions: "test")
        await harness.simulateUserSpeech()

        try await harness.responder.forceResponse()
        try await harness.responder.forceResponse()
        try await Task.sleep(for: .milliseconds(10))
        #expect(await harness.responseRequestCount() == 1)

        await harness.deliverManualAnswer("Ответ")
        try await Task.sleep(for: .milliseconds(20))
        let events = collector.events
        #expect(events.contains(.responseStarted(responseID: "manual-1", trigger: .manual)))
        #expect(events.contains(.textDelta(responseID: "manual-1", text: "Ответ")))
        #expect(events.contains(.completed(responseID: "manual-1")))
        let startIndex = events.firstIndex(of: .responseStarted(responseID: "manual-1", trigger: .manual))
        let doneIndex = events.firstIndex(of: .completed(responseID: "manual-1"))
        #expect(startIndex != nil && doneIndex != nil && startIndex! < doneIndex!)

        await harness.responder.stop()
        listener.cancel()
    }

    @Test(arguments: HarnessKind.allCases)
    func injectedContextCountsAsContextForAnswerNow(_ kind: HarnessKind) async throws {
        let harness = kind.make()
        try await harness.responder.start(instructions: "test")
        try await harness.responder.injectContext("Текст с экрана: задача про LRU-кэш")
        try await harness.responder.forceResponse()
        try await Task.sleep(for: .milliseconds(10))
        #expect(await harness.responseRequestCount() == 1)
        await harness.responder.stop()
    }

    @Test(arguments: HarnessKind.allCases)
    func resetContextDropsAccumulatedContext(_ kind: HarnessKind) async throws {
        let harness = kind.make()
        try await harness.responder.start(instructions: "test")
        await harness.simulateUserSpeech()
        await harness.responder.resetContext()
        await #expect(throws: RealtimeClientError.noContext) {
            try await harness.responder.forceResponse()
        }
        await harness.responder.stop()
    }

    @Test func openAIInjectionSendsSystemItemWithPrefix() async throws {
        let harness = OpenAIHarness()
        try await harness.responder.start(instructions: "test")
        try await harness.responder.injectContext("  экран  ")
        let payload = try #require(harness.transport.sentEvents.compactMap { event -> ConversationItemPayload? in
            if case .conversationItemCreate(let payload) = event { payload } else { nil }
        }.first)
        #expect(payload.role == .system)
        #expect(payload.id.hasPrefix("ctx_"))
        #expect(payload.text == RealtimeInstructions.injectedContextPrefix + "экран")
        await harness.responder.stop()
    }
}
