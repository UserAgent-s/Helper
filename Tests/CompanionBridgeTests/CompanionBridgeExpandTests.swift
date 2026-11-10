import ClaudeClient
import CompanionProtocol
import Domain
import Foundation
import Persistence
import Testing
@testable import CompanionBridge

private final class ScriptedAnthropicTransport: AnthropicMessagesTransport, @unchecked Sendable {
    let lines: [String]
    private let lock = NSLock()
    private var _bodies: [Data] = []

    init(lines: [String]) { self.lines = lines }

    var bodies: [Data] { lock.withLock { _bodies } }

    func open(_ request: URLRequest) async throws -> AnthropicHTTPResponse {
        lock.withLock { _bodies.append(request.httpBody ?? Data()) }
        let lines = self.lines
        return AnthropicHTTPResponse(status: 200, lines: AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) { (500, Data()) }
}

private let sse = [
    #"data: {"type":"message_start","message":{"id":"msg_1","model":"claude-sonnet-5-5","usage":{"input_tokens":40,"cache_read_input_tokens":900,"output_tokens":1}}}"#,
    #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Я строил "}}"#,
    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"платёжный шлюз."}}"#,
    #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}"#,
    #"data: {"type":"message_stop"}"#,
]

@Suite struct CompanionBridgeExpandTests {
    private func makeExpansion(transport: ScriptedAnthropicTransport, repository: SQLiteSessionRepository?, session: SessionID?, key: String? = "sk-ant-api03-k") -> ClaudeExpansionClient {
        ClaudeExpansionClient(
            client: ClaudeMessagesClient(transport: transport, apiKey: { key }),
            hasKey: { key != nil },
            profile: { _ in ProfileSnapshot(source: .legacyText, documents: [ProfileDocument(relativePath: "background.txt", text: "PHP")], fingerprint: "f", estimatedTokens: 1, sizeStatus: .ok) },
            activeSession: { session },
            store: repository
        )
    }

    private func makeBridge(expansions: (any ExpansionRequesting)?) async -> (CompanionBridge, ManualFeeds, EventSink) {
        let bridge = CompanionBridge(control: FakeDomainControl(), expansions: expansions, now: { Date(timeIntervalSince1970: 1_000) })
        let feeds = ManualFeeds()
        let sink = EventSink()
        await bridge.setPublisher { event in await sink.append(event) }
        await bridge.start(feeds: feeds.feeds)
        return (bridge, feeds, sink)
    }

    private func answer(_ feeds: ManualFeeds, sink: EventSink) async {
        let text = "- Платёжный шлюз RedCore\n- Kafka и идемпотентность\n"
        feeds.answers.yield(AnswerStreamUpdate(responseID: "r1", trigger: .automatic, event: .streaming(text: text)))
        feeds.answers.yield(AnswerStreamUpdate(responseID: "r1", trigger: .automatic, event: .completed(finalText: text)))
        await waitUntil { await sink.types.contains("answer.done") }
    }

    @Test func expandPointStreamsDeepEventsAndPersists() async throws {
        let database = SQLiteDatabase(path: ":memory:")
        let repository = SQLiteSessionRepository(database: database)
        let session = try await repository.create(kind: .assistant, mode: .answers, at: Date(timeIntervalSince1970: 1_000))
        let transport = ScriptedAnthropicTransport(lines: sse)
        let (bridge, feeds, sink) = await makeBridge(expansions: makeExpansion(transport: transport, repository: repository, session: session.id))
        #expect(bridge.capabilities.contains("expand"))
        await answer(feeds, sink: sink)
        feeds.transcripts.yield(TranscriptEvent(speaker: .them, itemID: "t1", text: "Расскажите про шлюз", isFinal: true))
        await waitUntil { await sink.types.contains("transcript.delta") }

        let outcome = await bridge.perform(.expand(.init(pointId: "r1.0", format: .short, language: .ru)), deviceId: "d1")
        #expect(outcome == .ok)
        await waitUntil { await sink.types.contains("deep.done") }

        let deep = await sink.events.filter { ["deep.started", "deep.delta", "deep.done"].contains($0.type) }
        #expect(deep.map(\.type) == ["deep.started", "deep.delta", "deep.delta", "deep.done"])
        guard case .deepStarted(let started) = deep[0], case .deepDelta(let second) = deep[2], case .deepDone(let done) = deep[3] else {
            Issue.record("unexpected events")
            return
        }
        #expect(started.pointId == "r1.0")
        #expect(started.model == .sonnet)
        #expect(started.format == .short)
        #expect(second.offset == "Я строил ".utf16.count)
        #expect(done.status == .completed)
        #expect(done.errorCode == nil)

        let body = String(decoding: try #require(transport.bodies.first), as: UTF8.self)
        #expect(body.contains("Платёжный шлюз RedCore"))
        #expect(body.contains("Собеседник: Расскажите про шлюз"))

        let record = try #require(try await repository.expansionRecord(id: started.requestId))
        #expect(record.status == "completed")
        #expect(record.text == "Я строил платёжный шлюз.")
        #expect(record.pointID == "r1.0")
        #expect(record.cacheReadTokens == 900)
        let detail = try #require(try await repository.detail(sessionID: session.id))
        #expect(detail.expansions.map(\.text) == ["Я строил платёжный шлюз."])
    }

    @Test func followUpByParentRequestId() async throws {
        let transport = ScriptedAnthropicTransport(lines: sse)
        let (bridge, feeds, sink) = await makeBridge(expansions: makeExpansion(transport: transport, repository: nil, session: nil))
        await answer(feeds, sink: sink)
        #expect(await bridge.perform(.expand(.init(pointId: "r1.1")), deviceId: "d1") == .ok)
        await waitUntil { await sink.types.filter { $0 == "deep.done" }.count == 1 }
        guard case .deepStarted(let first) = await sink.events.first(where: { $0.type == "deep.started" }) else { Issue.record("no start"); return }
        #expect(await bridge.perform(.expand(.init(freeText: "А подробнее?", parentRequestId: first.requestId)), deviceId: "d1") == .ok)
        await waitUntil { await sink.types.filter { $0 == "deep.done" }.count == 2 }
        #expect(transport.bodies.count == 2)
        #expect(await bridge.perform(.expand(.init(freeText: "x", parentRequestId: "missing")), deviceId: "d1") == .rejected(code: "unknown_expansion"))
    }

    @Test func rejections() async {
        let transport = ScriptedAnthropicTransport(lines: sse)
        let (none, _, _) = await makeBridge(expansions: nil)
        #expect(!none.capabilities.contains("expand"))
        #expect(await none.perform(.expand(.init(freeText: "q")), deviceId: "d") == .rejected(code: "not_available"))
        let (noKey, _, _) = await makeBridge(expansions: makeExpansion(transport: transport, repository: nil, session: nil, key: nil))
        #expect(await noKey.perform(.expand(.init(freeText: "q")), deviceId: "d") == .rejected(code: "claude_unavailable"))
        let (bridge, _, _) = await makeBridge(expansions: makeExpansion(transport: transport, repository: nil, session: nil))
        #expect(await bridge.perform(.expand(.init(pointId: "nope.0")), deviceId: "d") == .rejected(code: "unknown_point"))
        #expect(transport.bodies.isEmpty)
    }
}
