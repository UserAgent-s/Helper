import Foundation
import Testing
@testable import ClaudeClient

private final class Timeline: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String] = []
    func add(_ entry: String) { lock.withLock { _entries.append(entry) } }
    var entries: [String] { lock.withLock { _entries } }
}

@Suite struct ClaudeMessagesClientTests {
    private func request() -> ClaudeMessagesRequest {
        ClaudeMessagesRequest(model: .sonnet, maxTokens: 1_024, system: [ClaudeSystemBlock(text: "rules"), ClaudeSystemBlock(text: "<profile>p</profile>", cacheTTL: .oneHour)], messages: [.user("q")])
    }

    private func collect(_ stream: AsyncStream<ClaudeStreamEvent>) async -> [ClaudeStreamEvent] {
        var events: [ClaudeStreamEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test func firstTextDeltaArrivesBeforeMessageStopIsRead() async throws {
        let lines = try FakeAnthropicTransport.fixtureLines("thinking_then_text")
        let stopIndex = try #require(lines.firstIndex { $0.contains("\"message_stop\"") })
        let timeline = Timeline()
        let transport = FakeAnthropicTransport(lines: lines, onLine: { index in
            if index == stopIndex { timeline.add("transport:message_stop") }
        })
        let client = ClaudeMessagesClient(transport: transport, apiKey: { "sk-ant-api03-key" })
        for await event in client.stream(request()) {
            switch event {
            case .textDelta: timeline.add("delta")
            case .completed: timeline.add("completed")
            default: break
            }
        }
        let entries = timeline.entries
        let firstDelta = try #require(entries.firstIndex(of: "delta"))
        let stop = try #require(entries.firstIndex(of: "transport:message_stop"))
        #expect(firstDelta < stop)
        #expect(entries.last == "completed")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-api03-key")
    }

    @Test func missingKeyFailsWithoutNetwork() async {
        let transport = FakeAnthropicTransport()
        let events = await collect(ClaudeMessagesClient(transport: transport, apiKey: { nil }).stream(request()))
        #expect(events == [.failed(.missingAPIKey)])
        #expect(transport.requests.isEmpty)
    }

    @Test func httpErrorBodyIsParsed() async {
        let body = #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"},"request_id":"req_1"}"#
        let transport = FakeAnthropicTransport(status: 429, lines: [body])
        let events = await collect(ClaudeMessagesClient(transport: transport, apiKey: { "k" }).stream(request()))
        #expect(events == [.failed(.http(status: 429, type: "rate_limit_error", message: "slow down"))])
        #expect(ClaudeFailure.http(status: 429, type: nil, message: nil).isRetryable)
        #expect(!ClaudeFailure.http(status: 400, type: nil, message: nil).isRetryable)
    }

    @Test func transportErrorBecomesFailedEvent() async {
        let transport = FakeAnthropicTransport(failure: URLError(.notConnectedToInternet))
        let events = await collect(ClaudeMessagesClient(transport: transport, apiKey: { "k" }).stream(request()))
        #expect(events == [.failed(.transport("URLError -1009"))])
    }

    @Test func invalidRequestFailsBeforeNetwork() async {
        var bad = request()
        bad.messages = []
        let transport = FakeAnthropicTransport()
        let events = await collect(ClaudeMessagesClient(transport: transport, apiKey: { "k" }).stream(bad))
        #expect(events == [.failed(.invalidRequest(.firstMessageMustBeUser))])
        #expect(transport.requests.isEmpty)
    }

    @Test func prewarmSendsNonStreamingZeroMaxTokensAndReadsUsage() async throws {
        let body = #"{"id":"msg_w","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[],"stop_reason":"max_tokens","usage":{"input_tokens":3,"cache_creation_input_tokens":20000,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":20000,"ephemeral_5m_input_tokens":0},"output_tokens":0}}"#
        let transport = FakeAnthropicTransport(sendBody: Data(body.utf8))
        let result = await ClaudeMessagesClient(transport: transport, apiKey: { "k" }).prewarm(request())
        let warm = try result.get()
        #expect(warm.stopReason == .maxTokens)
        #expect(warm.usage.cacheCreation1hTokens == 20_000)
        let sent = try #require(transport.requests.first?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(object["max_tokens"] as? Int == 0)
        #expect(object["stream"] == nil)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "accept") == "application/json")
    }
}
