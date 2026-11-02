import Domain
import Foundation
import Testing
@testable import AnthropicClient

final class FakeAnthropicTransport: AnthropicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _terminated = 0
    let status: Int
    let headers: [String: String]
    let lines: [String]
    let error: Error?
    let lineDelay: Duration

    init(status: Int = 200, headers: [String: String] = [:], lines: [String], error: Error? = nil, lineDelay: Duration = .zero) {
        self.status = status
        self.headers = headers
        self.lines = lines
        self.error = error
        self.lineDelay = lineDelay
    }

    var requests: [URLRequest] { lock.withLock { _requests } }
    var terminatedCount: Int { lock.withLock { _terminated } }

    func send(_ request: URLRequest) async throws -> AnthropicHTTPResponse {
        lock.withLock { _requests.append(request) }
        if let error { throw error }
        let lines = self.lines
        let delay = lineDelay
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                for line in lines {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    if Task.isCancelled { break }
                    continuation.yield(line)
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.lock.withLock { self?._terminated += 1 }
            }
        }
        return AnthropicHTTPResponse(statusCode: status, headers: headers, lines: stream)
    }
}

enum SSE {
    static func event(_ name: String, _ json: String) -> [String] {
        ["event: \(name)", "data: \(json)", ""]
    }

    static func successfulStream(text: [String], model: String = "claude-opus-5-5", stopReason: String = "end_turn") -> [String] {
        var lines = event("message_start", #"{"type":"message_start","message":{"id":"msg_1","type":"message","model":"\#(model)","usage":{"input_tokens":120,"cache_creation_input_tokens":900,"cache_read_input_tokens":0,"output_tokens":1}}}"#)
        lines += event("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#)
        lines += event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#)
        lines += event("ping", #"{"type":"ping"}"#)
        lines += event("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#)
        for chunk in text {
            let escaped = chunk.replacingOccurrences(of: "\"", with: "\\\"")
            lines += event("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\#(escaped)"}}"#)
        }
        lines += event("content_block_stop", #"{"type":"content_block_stop","index":1}"#)
        lines += event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)"},"usage":{"output_tokens":42}}"#)
        lines += event("message_stop", #"{"type":"message_stop"}"#)
        return lines
    }
}

private func makeRequest(fallback: Bool = false, effort: String? = "low", trigger: AnswerTriggerKind = .automatic) -> TextAnswerRequest {
    TextAnswerRequest(
        modelID: "claude-opus-5-5",
        systemInstructions: "SYSTEM RULES",
        transcript: "Как работает индекс?",
        priorExchanges: [],
        trigger: trigger,
        maxOutputTokens: 4096,
        reasoningEffort: effort,
        useServerSideFallback: fallback
    )
}

private func collect(_ stream: AsyncThrowingStream<TextAnswerEvent, Error>) async -> (events: [TextAnswerEvent], error: Error?) {
    var events: [TextAnswerEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

@Suite struct AnthropicMessagesAnswerClientTests {
    @Test func streamsTextUsageAndCompletionFromSSE() async {
        let transport = FakeAnthropicTransport(lines: SSE.successfulStream(text: ["Индекс ", "B-tree."]))
        let client = AnthropicMessagesAnswerClient(transport: transport, apiKeyProvider: { "sk-ant-test-key-000000" })
        let result = await collect(client.streamAnswer(makeRequest()))
        #expect(result.error == nil)
        #expect(result.events.first == .started(servedModel: "claude-opus-5-5"))
        #expect(result.events.contains(.textDelta("Индекс ")))
        #expect(result.events.contains(.textDelta("B-tree.")))
        #expect(result.events.contains(.usage(ProviderUsage(inputTokens: 120, cachedInputTokens: 0, cacheCreationInputTokens: 900, outputTokens: 42))))
        #expect(result.events.last == .completed(stopReason: "end_turn"))
    }

    @Test func buildsDirectMessagesRequestWithCachedSystemPromptAndNoSamplingParams() throws {
        let urlRequest = try AnthropicMessagesAnswerClient.makeURLRequest(makeRequest(), apiKey: "sk-ant-test-key-000000")
        #expect(urlRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test-key-000000")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-opus-5-5")
        #expect(json["stream"] as? Bool == true)
        #expect(json["max_tokens"] as? Int == 4096)
        #expect(json["temperature"] == nil)
        #expect(json["thinking"] == nil)
        #expect(json["fallbacks"] == nil)
        #expect((json["output_config"] as? [String: Any])?["effort"] as? String == "low")
        let system = try #require(json["system"] as? [[String: Any]])
        #expect(system.first?["text"] as? String == "SYSTEM RULES")
        #expect((system.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect((messages.first?["content"] as? String)?.contains("<transcript>\nКак работает индекс?\n</transcript>") == true)
    }

    @Test func customUserMessageReplacesTranscriptEnvelope() throws {
        let request = TextAnswerRequest(
            modelID: "claude-opus-5-5",
            systemInstructions: "EXPANSION RULES",
            transcript: "",
            priorExchanges: [],
            trigger: .manual,
            maxOutputTokens: 4096,
            reasoningEffort: nil,
            useServerSideFallback: false,
            userMessage: AnswerInstructionsBuilder.expansionUserMessage(question: "Why Redis?", answer: "Latency.")
        )
        let urlRequest = try AnthropicMessagesAnswerClient.makeURLRequest(request, apiKey: "sk-ant-test-key-000000")
        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? String)
        #expect(content.contains("<short_answer>\nLatency.\n</short_answer>"))
        #expect(content.contains("<question>\nWhy Redis?\n</question>"))
        #expect(!content.contains("<transcript>"))
        #expect(!content.contains("TRIGGER:"))
    }

    @Test func serverSideFallbackAddsBetaHeaderAndDefaultMode() throws {
        let urlRequest = try AnthropicMessagesAnswerClient.makeURLRequest(makeRequest(fallback: true), apiKey: "sk-ant-test-key-000000")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let json = try #require(try JSONSerialization.jsonObject(with: urlRequest.httpBody!) as? [String: Any])
        #expect(json["fallbacks"] as? String == "default")
    }

    @Test func customModelWithoutEffortOmitsOutputConfig() throws {
        let urlRequest = try AnthropicMessagesAnswerClient.makeURLRequest(makeRequest(effort: nil), apiKey: "sk-ant-x-000000000000000")
        let json = try #require(try JSONSerialization.jsonObject(with: urlRequest.httpBody!) as? [String: Any])
        #expect(json["output_config"] == nil)
    }

    @Test func missingKeyFailsWithoutNetwork() async {
        let transport = FakeAnthropicTransport(lines: [])
        let client = AnthropicMessagesAnswerClient(transport: transport, apiKeyProvider: { nil })
        let result = await collect(client.streamAnswer(makeRequest()))
        #expect(result.error as? AnswerProviderError == .missingAPIKey(.anthropicClaude))
        #expect(transport.requests.isEmpty)
    }

    @Test(arguments: [
        (401, "authentication_error", AnswerProviderError.authentication),
        (402, "billing_error", AnswerProviderError.billing),
        (403, "permission_error", AnswerProviderError.permission),
        (529, "overloaded_error", AnswerProviderError.overloaded),
        (500, "api_error", AnswerProviderError.serverError(status: 500)),
    ])
    func mapsHTTPErrors(status: Int, type: String, expected: AnswerProviderError) async {
        let body = #"{"type":"error","error":{"type":"\#(type)","message":"details"},"request_id":"req_1"}"#
        let transport = FakeAnthropicTransport(status: status, lines: [body])
        let client = AnthropicMessagesAnswerClient(transport: transport, apiKeyProvider: { "sk-ant-test-key-000000" })
        let result = await collect(client.streamAnswer(makeRequest()))
        #expect(result.error as? AnswerProviderError == expected)
        #expect(result.events.isEmpty)
    }

    @Test func rateLimitCarriesRetryAfter() async {
        let body = #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#
        let transport = FakeAnthropicTransport(status: 429, headers: ["retry-after": "17"], lines: [body])
        let client = AnthropicMessagesAnswerClient(transport: transport, apiKeyProvider: { "sk-ant-test-key-000000" })
        let result = await collect(client.streamAnswer(makeRequest()))
        #expect(result.error as? AnswerProviderError == .rateLimited(retryAfterSeconds: 17))
    }

    @Test func unknownModelIsReportedAsModelNotFound() async {
        let body = #"{"type":"error","error":{"type":"not_found_error","message":"model: claude-nope"}}"#
        let transport = FakeAnthropicTransport(status: 404, lines: [body])
        let client = AnthropicMessagesAnswerClient(transport: transport, apiKeyProvider: { "sk-ant-test-key-000000" })
        let result = await collect(client.streamAnswer(makeRequest()))
        #expect(result.error as? AnswerProviderError == .modelNotFound("model: claude-nope"))
    }

    @Test func networkFailureIsMappedAndNeverRetriedElsewhere() async {
        let transport = FakeAnthropicTransport(lines: [], error: URLError(.notConnectedToInternet))
        let client = AnthropicMessagesAnswerClient(transport: transport, apiKeyProvider: { "sk-ant-test-key-000000" })
        let result = await collect(client.streamAnswer(makeRequest()))
        guard case .network = result.error as? AnswerProviderError else {
            Issue.record("expected network error, got \(String(describing: result.error))")
            return
        }
        #expect(transport.requests.count == 1)
    }

    @Test func midStreamOverloadedErrorEventFailsAfterPartialText() async {
        var lines = SSE.event("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":1}}}"#)
        lines += SSE.event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Частичный"}}"#)
        lines += SSE.event("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        let client = AnthropicMessagesAnswerClient(transport: FakeAnthropicTransport(lines: lines), apiKeyProvider: { "sk-ant-test-key-000000" })
        let result = await collect(client.streamAnswer(makeRequest()))
        #expect(result.events.contains(.textDelta("Частичный")))
        #expect(result.error as? AnswerProviderError == .overloaded)
    }

    @Test func truncatedStreamWithoutMessageStopIsAnError() async {
        let lines = Array(SSE.successfulStream(text: ["a"]).dropLast(3))
        let client = AnthropicMessagesAnswerClient(transport: FakeAnthropicTransport(lines: lines), apiKeyProvider: { "sk-ant-test-key-000000" })
        let result = await collect(client.streamAnswer(makeRequest()))
        #expect(result.error as? AnswerProviderError == .network("stream_ended_without_message_stop"))
    }

    @Test func refusalWithoutTextIsReported() async {
        var lines = SSE.event("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":0}}}"#)
        lines += SSE.event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":0}}"#)
        lines += SSE.event("message_stop", #"{"type":"message_stop"}"#)
        let client = AnthropicMessagesAnswerClient(transport: FakeAnthropicTransport(lines: lines), apiKeyProvider: { "sk-ant-test-key-000000" })
        let result = await collect(client.streamAnswer(makeRequest()))
        #expect(result.error as? AnswerProviderError == .refused)
    }

    @Test func fallbackBlockReportsTheModelThatActuallyAnswered() async {
        var lines = SSE.event("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":0}}}"#)
        lines += SSE.event("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"}}}"#)
        lines += SSE.event("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ok"}}"#)
        lines += SSE.event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#)
        lines += SSE.event("message_stop", #"{"type":"message_stop"}"#)
        let client = AnthropicMessagesAnswerClient(transport: FakeAnthropicTransport(lines: lines), apiKeyProvider: { "sk-ant-test-key-000000" })
        let result = await collect(client.streamAnswer(makeRequest(fallback: true)))
        #expect(result.events.contains(.servedByFallback(model: "claude-opus-4-8")))
    }

    @Test func cancellingConsumerTearsDownTheHTTPStream() async throws {
        let transport = FakeAnthropicTransport(lines: SSE.successfulStream(text: Array(repeating: "x", count: 200)), lineDelay: .milliseconds(20))
        let client = AnthropicMessagesAnswerClient(transport: transport, apiKeyProvider: { "sk-ant-test-key-000000" })
        let consumer = Task {
            var count = 0
            for try await _ in client.streamAnswer(makeRequest()) { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(150))
        consumer.cancel()
        _ = try? await consumer.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while transport.terminatedCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(transport.terminatedCount == 1)
    }

    @Test func errorsNeverContainTheAPIKey() async {
        let secret = "sk-ant-api03-SECRETSECRETSECRET"
        let body = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        let client = AnthropicMessagesAnswerClient(transport: FakeAnthropicTransport(status: 401, lines: [body]), apiKeyProvider: { secret })
        let result = await collect(client.streamAnswer(makeRequest()))
        #expect(!String(describing: result.error as Any).contains(secret))
    }
}

@Suite struct ServerSentEventParserTests {
    @Test func parsesEventsSeparatedByBlankLines() {
        var parser = ServerSentEventParser()
        var events: [ServerSentEvent] = []
        for line in ["event: ping", "data: {\"type\":\"ping\"}", "", ": comment", "data: a", "data: b", "\r"] {
            if let event = parser.consume(line: line) { events.append(event) }
        }
        #expect(events == [ServerSentEvent(event: "ping", data: "{\"type\":\"ping\"}"), ServerSentEvent(event: nil, data: "a\nb")])
    }

    @Test func finishFlushesTrailingEvent() {
        var parser = ServerSentEventParser()
        _ = parser.consume(line: "data: tail")
        #expect(parser.finish() == ServerSentEvent(event: nil, data: "tail"))
    }
}
