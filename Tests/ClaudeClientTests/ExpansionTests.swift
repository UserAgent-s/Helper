import Domain
import Foundation
import Testing
@testable import ClaudeClient

actor MemoryExpansionStore: DeepExpansionStoring {
    private(set) var saves: [DeepExpansionRecord] = []
    var responseMap: [String: UUID] = [:]

    func setResponse(_ id: String, _ uuid: UUID) { responseMap[id] = uuid }
    func saveExpansion(_ record: DeepExpansionRecord) async throws { saves.append(record) }
    func expansionRecord(id: String) async throws -> DeepExpansionRecord? { saves.last { $0.id == id } }
    func questionAnswerID(responseID: String) async throws -> UUID? { responseMap[responseID] }
}

final class Sequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> String { lock.withLock { value += 1; return "exp-\(value)" } }
}

@Suite struct ExpansionTests {
    private let session = SessionID()
    private let snapshot = ProfileSnapshot(
        source: .markdownFolder(path: "/p"),
        documents: [ProfileDocument(relativePath: "02_CURRENT_PROFILE.md", text: "Senior PHP, RedCore payments")],
        fingerprint: "fp",
        estimatedTokens: 10,
        sizeStatus: .ok
    )

    private func make(transport: FakeAnthropicTransport, store: MemoryExpansionStore = MemoryExpansionStore(), key: String? = "sk-ant-api03-k", session: SessionID? = nil, prewarm: Bool = true) -> ClaudeExpansionClient {
        let snapshot = self.snapshot
        let ids = Sequence()
        return ClaudeExpansionClient(
            client: ClaudeMessagesClient(transport: transport, apiKey: { key }),
            hasKey: { key != nil },
            profile: { _ in snapshot },
            activeSession: { session },
            store: store,
            settings: { ClaudeExpansionSettings(defaultModel: .sonnet, effort: .low, maxTokens: 1_024, prewarmOnSessionStart: prewarm) },
            makeID: { ids.next() }
        )
    }

    private func drain(_ stream: AsyncStream<ExpansionEvent>) async -> [ExpansionEvent] {
        var events: [ExpansionEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func json(_ value: Any?) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func pointRequest(format: ExpansionFormat = .structured, language: ExpansionLanguage = .ru) -> ExpansionRequest {
        ExpansionRequest(
            source: .point(answerID: "resp_1", pointID: "resp_1.0", pointText: "Опыт с платежами", answerText: "- Опыт с платежами\n- Kafka"),
            format: format,
            language: language,
            transcriptTail: ["Собеседник: расскажите про платежи"]
        )
    }

    @Test func streamsDeltasWithUTF16OffsetsAndSavesRecord() async throws {
        let store = MemoryExpansionStore()
        await store.setResponse("resp_1", UUID(uuidString: "8F0C6B2A-3D4E-4F50-9A1B-2C3D4E5F6A7B")!)
        let client = make(transport: try .fixture("thinking_then_text"), store: store, session: session)
        let events = await drain(try await client.expand(pointRequest()))
        #expect(events.first == .started(expansionID: "exp-1", modelID: "claude-sonnet-5-5", format: .structured, language: .ru))
        #expect(events[1] == .delta(expansionID: "exp-1", offset: 0, text: "В RedCore я "))
        #expect(events[2] == .delta(expansionID: "exp-1", offset: "В RedCore я ".utf16.count, text: "вёл платежи."))
        #expect(events.last == .finished(expansionID: "exp-1", outcome: .completed, errorCode: nil))
        let saves = await store.saves
        #expect(saves.count == 2)
        #expect(saves[0].status == "streaming")
        let final = try #require(saves.last)
        #expect(final.status == "completed")
        #expect(final.text == "В RedCore я вёл платежи.")
        #expect(final.sessionID == session)
        #expect(final.questionAnswerID == UUID(uuidString: "8F0C6B2A-3D4E-4F50-9A1B-2C3D4E5F6A7B"))
        #expect(final.sourceKind == "point")
        #expect(final.pointID == "resp_1.0")
        #expect(final.cacheReadTokens == 21_000)
        #expect(final.outputTokens == 87)
        #expect(final.ttftMs != nil)
        #expect((final.estimatedCostUSD ?? 0) > 0)
    }

    @Test func formatAndLanguageLiveOnlyInUserTurnAfterCachePoint() async throws {
        let transport = try FakeAnthropicTransport.fixture("thinking_then_text")
        let client = make(transport: transport)
        _ = await drain(try await client.expand(pointRequest(format: .star, language: .en)))
        _ = await drain(try await client.expand(pointRequest(format: .short, language: .ru)))
        let first = try body(transport.requests[0])
        let second = try body(transport.requests[1])
        let firstSystem = try JSONSerialization.data(withJSONObject: try #require(first["system"]), options: .sortedKeys)
        let secondSystem = try JSONSerialization.data(withJSONObject: try #require(second["system"]), options: .sortedKeys)
        #expect(firstSystem == secondSystem)
        let systemText = String(decoding: firstSystem, as: UTF8.self)
        #expect(!systemText.contains("Формат:"))
        #expect(!systemText.contains("Язык:"))
        #expect(systemText.contains("<profile>"))
        let system = try #require(first["system"] as? [[String: Any]])
        #expect(system.count == 2)
        #expect(system[1]["cache_control"] != nil)
        let userText = json(first["messages"])
        #expect(userText.contains("STAR"))
        #expect(userText.contains("английский"))
        #expect(userText.contains("Опыт с платежами"))
        #expect(userText.contains("расскажите про платежи"))
    }

    @Test func followUpIsAppendOnlyAndByteIdenticalPrefix() async throws {
        let transport = try FakeAnthropicTransport.fixture("thinking_then_text")
        let store = MemoryExpansionStore()
        let client = make(transport: transport, store: store, session: session)
        _ = await drain(try await client.expand(pointRequest()))
        let followEvents = await drain(try await client.followUp(expansionID: "exp-1", question: "А какие были ограничения?"))
        #expect(followEvents.last == .finished(expansionID: "exp-2", outcome: .completed, errorCode: nil))
        _ = await drain(try await client.followUp(expansionID: "exp-2", question: "Ещё короче"))

        let bodies = try transport.requests.map { try body($0) }
        let encode: (Any) throws -> Data = { try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
        #expect(try encode(bodies[0]["system"]!) == encode(bodies[1]["system"]!))
        #expect(try encode(bodies[1]["system"]!) == encode(bodies[2]["system"]!))
        let m0 = try #require(bodies[0]["messages"] as? [Any])
        let m1 = try #require(bodies[1]["messages"] as? [Any])
        let m2 = try #require(bodies[2]["messages"] as? [Any])
        #expect(m0.count == 1 && m1.count == 3 && m2.count == 5)
        for (index, message) in m0.enumerated() { #expect(try encode(message) == encode(m1[index])) }
        for (index, message) in m1.enumerated() { #expect(try encode(message) == encode(m2[index])) }
        let assistant = try #require(m1[1] as? [String: Any])
        #expect(assistant["role"] as? String == "assistant")
        #expect(json(assistant["content"]).contains("В RedCore я вёл платежи."))
        #expect(!json(m1[2]).contains("Формат:"))
        let saves = await store.saves
        #expect(saves.last { $0.id == "exp-2" }?.parentID == "exp-1")
        #expect(saves.last { $0.id == "exp-2" }?.sourceKind == "follow_up")
        #expect(saves.last { $0.id == "exp-3" }?.parentID == "exp-2")
    }

    @Test func prewarmIsNonStreamingZeroMaxTokensWithSameSystem() async throws {
        let body = #"{"id":"m","model":"claude-sonnet-5-5","content":[],"stop_reason":"max_tokens","usage":{"input_tokens":2,"cache_creation_input_tokens":900,"output_tokens":0}}"#
        let transport = FakeAnthropicTransport(lines: try FakeAnthropicTransport.fixtureLines("thinking_then_text"), sendBody: Data(body.utf8))
        let client = make(transport: transport)
        let result = await client.prewarm(sessionID: session)
        #expect(result?.usage.cacheCreationInputTokens == 900)
        _ = await drain(try await client.expand(pointRequest()))
        let warm = try self.body(transport.requests[0])
        let real = try self.body(transport.requests[1])
        #expect(warm["max_tokens"] as? Int == 0)
        #expect(warm["stream"] == nil)
        #expect(real["stream"] as? Bool == true)
        let encode: (Any) throws -> Data = { try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
        #expect(try encode(warm["system"]!) == encode(real["system"]!))
        #expect(try encode(warm["output_config"]!) == encode(real["output_config"]!))
        #expect(warm["model"] as? String == real["model"] as? String)
    }

    @Test func sessionStartTriggersPrewarmOnlyWhenEnabled() async throws {
        let body = #"{"id":"m","model":"claude-sonnet-5-5","content":[],"stop_reason":"max_tokens","usage":{"input_tokens":2}}"#
        let transport = FakeAnthropicTransport(sendBody: Data(body.utf8))
        let client = make(transport: transport)
        let (events, continuation) = AsyncStream<SessionEvent>.makeStream()
        await client.observe(events)
        continuation.yield(.started(session, resumed: false))
        for _ in 0..<200 where transport.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(transport.requests.count == 1)
        continuation.finish()

        let disabledTransport = FakeAnthropicTransport(sendBody: Data(body.utf8))
        let disabled = make(transport: disabledTransport, prewarm: false)
        let (events2, continuation2) = AsyncStream<SessionEvent>.makeStream()
        await disabled.observe(events2)
        continuation2.yield(.started(session, resumed: false))
        continuation2.finish()
        try await Task.sleep(for: .milliseconds(50))
        #expect(disabledTransport.requests.isEmpty)
    }

    @Test func refusalIsNotContinuable() async throws {
        let client = make(transport: try .fixture("refusal_midstream"))
        let events = await drain(try await client.expand(pointRequest()))
        #expect(events.last == .finished(expansionID: "exp-1", outcome: .refused, errorCode: "refused_cyber"))
        await #expect(throws: ExpansionRejection.unknownExpansion) {
            _ = try await client.followUp(expansionID: "exp-1", question: "ещё")
        }
    }

    @Test func truncationAndFailuresMapToCodes() async throws {
        let truncated = await drain(try await make(transport: try .fixture("max_tokens")).expand(pointRequest()))
        #expect(truncated.last == .finished(expansionID: "exp-1", outcome: .truncated, errorCode: "max_tokens"))
        let overloaded = await drain(try await make(transport: try .fixture("error_midstream")).expand(pointRequest()))
        #expect(overloaded.last == .finished(expansionID: "exp-1", outcome: .failed, errorCode: "overloaded"))
        let unauthorized = await drain(try await make(transport: FakeAnthropicTransport(status: 401, lines: [#"{"error":{"type":"authentication_error"}}"#])).expand(pointRequest()))
        #expect(unauthorized.last == .finished(expansionID: "exp-1", outcome: .failed, errorCode: "auth_failed"))
    }

    @Test func rejectsWithoutKeyBlankQuestionAndWithoutSessionDoesNotPersist() async throws {
        let transport = try FakeAnthropicTransport.fixture("thinking_then_text")
        let noKey = make(transport: transport, key: nil)
        #expect(await !noKey.isAvailable())
        await #expect(throws: ExpansionRejection.unavailable) { _ = try await noKey.expand(pointRequest()) }
        #expect(transport.requests.isEmpty)
        let store = MemoryExpansionStore()
        let client = make(transport: transport, store: store, session: nil)
        await #expect(throws: ExpansionRejection.emptyQuestion) { _ = try await client.expand(ExpansionRequest(source: .freeText("  "))) }
        _ = await drain(try await client.expand(ExpansionRequest(source: .freeText("Что такое идемпотентность?"))))
        #expect(await store.saves.isEmpty)
    }

    @Test func freeTextWithoutProfileHasNoCachePoint() throws {
        let system = ClaudePromptBuilder.system(profile: nil)
        #expect(system.count == 1)
        #expect(system[0].cacheTTL == nil)
        let turn = ClaudePromptBuilder.initialTurn(ExpansionRequest(source: .point(answerID: "a", pointID: "a.0", pointText: "p", answerText: "p"), note: "покажи пример"))
        #expect(turn.texts.last?.contains("Уточнение: покажи пример") == true)
    }
}
