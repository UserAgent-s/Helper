import Domain
import Foundation
import Testing
@testable import RealtimeClient

@Suite struct RealtimeProviderOptionsTests {
    private func makeClient(options: RealtimeSessionOptions, vad: RealtimeVADSettings = .safeDefault) -> (OpenAIRealtimeAnswerClient, FakeRealtimeWebSocketTransport) {
        let transport = FakeRealtimeWebSocketTransport()
        let client = OpenAIRealtimeAnswerClient(
            transport: transport,
            credentialProviding: FakeCredentialProviding(),
            vadSettingsProvider: { vad },
            sessionOptionsProvider: { options },
            latencyRecording: RecordingLatencyRecorder(),
            reconnectBaseDelay: .milliseconds(10),
            maxReconnectAttempts: 1
        )
        return (client, transport)
    }

    private func sessionJSON(_ transport: FakeRealtimeWebSocketTransport) throws -> [String: Any] {
        guard case .sessionUpdate = transport.sentEvents.first else { throw TransportTestError(message: "no session.update") }
        let data = try JSONEncoder().encode(transport.sentEvents.first!)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["session"] as? [String: Any])
    }

    @Test func selectedModelIsUsedInURLAndSession() async throws {
        let (client, transport) = makeClient(options: RealtimeSessionOptions(model: "gpt-realtime-2.1-mini", reasoningEffort: nil))
        try await client.start(instructions: "x")
        #expect(transport.lastURL?.absoluteString == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")
        let session = try sessionJSON(transport)
        #expect(session["model"] as? String == "gpt-realtime-2.1-mini")
        #expect(session["reasoning"] == nil)
        await client.stop()
    }

    @Test func reasoningEffortSentOnlyWhenSupported() async throws {
        let (client, transport) = makeClient(options: RealtimeSessionOptions(model: "gpt-realtime-2.1", reasoningEffort: "low"))
        try await client.start(instructions: "x")
        let session = try sessionJSON(transport)
        #expect((session["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        await client.stop()
    }

    @Test func manualOnlyModeDisablesServerAutoResponses() async throws {
        var vad = RealtimeVADSettings.safeDefault
        vad.automaticResponses = false
        let (client, transport) = makeClient(options: .default, vad: vad)
        try await client.start(instructions: "x")
        let session = try sessionJSON(transport)
        let turnDetection = try #require(((session["audio"] as? [String: Any])?["input"] as? [String: Any])?["turn_detection"] as? [String: Any])
        #expect(turnDetection["create_response"] as? Bool == false)
        await client.stop()
    }

    @Test func responseDoneUsageIsDecodedAndEmitted() async throws {
        let (client, transport) = makeClient(options: .default)
        let collector = AnswerEventCollector()
        await collector.start(consuming: client.events())
        try await client.start(instructions: "x")
        let json = """
        {"type":"response.done","response":{"id":"resp_1","status":"completed","output":[],"usage":{"total_tokens":300,"input_tokens":250,"output_tokens":50,"input_token_details":{"text_tokens":200,"audio_tokens":50,"cached_tokens":100,"cached_tokens_details":{"text_tokens":80,"audio_tokens":20}},"output_token_details":{"text_tokens":50,"audio_tokens":0}}}}
        """
        transport.emit(RealtimeServerEventDecoder.decode(Data(json.utf8)))
        let expected = ProviderUsage(inputTokens: 250, inputTextTokens: 200, inputAudioTokens: 50, cachedInputTokens: 100, cachedTextTokens: 80, cachedAudioTokens: 20, outputTokens: 50, outputTextTokens: 50)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await !collector.events.contains(.usage(responseID: "resp_1", expected)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await collector.events.contains(.usage(responseID: "resp_1", expected)))
        await client.stop()
    }

    @Test func responseDoneWithoutUsageDecodesWithNilUsage() {
        let json = #"{"type":"response.done","response":{"id":"r","status":"completed","output":[]}}"#
        #expect(RealtimeServerEventDecoder.decode(Data(json.utf8)) == .responseDone(responseID: "r", status: "completed", outputItemIDs: [], usage: nil))
    }

    @Test func notAuthenticatedMapsToMissingKeyForUI() {
        #expect(RealtimeClientError.notAuthenticated.answerProviderError == .missingAPIKey(.openAIRealtime))
    }
}
