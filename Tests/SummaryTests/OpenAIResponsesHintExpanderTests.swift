import Domain
import Foundation
import Testing
@testable import Summary

private final class RecordingTransport: ResponsesAPITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    let response: Result<Data, Error>

    init(response: Result<Data, Error>) { self.response = response }

    var requestBodies: [Data] { lock.withLock { bodies } }

    func createResponse(requestBody: Data, apiKey: String) async throws -> Data {
        lock.withLock { bodies.append(requestBody) }
        return try response.get()
    }
}

private struct StaticSecret: SecretStoring {
    let key: String?
    func store(apiKey: String) throws {}
    func retrieveAPIKey() throws -> String? { key }
    func deleteAPIKey() throws {}
}

@Suite struct OpenAIResponsesHintExpanderTests {
    @Test func sendsInstructionsAndExpansionMessageAndReturnsWholeText() async throws {
        let payload = """
        {"output":[{"type":"message","content":[{"type":"output_text","text":"Deep explanation"}]}],"usage":{"input_tokens":10,"output_tokens":5}}
        """
        let transport = RecordingTransport(response: .success(Data(payload.utf8)))
        let expander = OpenAIResponsesHintExpander(secretStoring: StaticSecret(key: "sk-test"), transport: transport, modelIDProvider: { "gpt-5.6-luna" }, instructionsProvider: { "SYS" })
        var collected: [String] = []
        for try await delta in expander.expand(HintExpansionRequest(hintID: UUID(), question: "Why?", answer: "Because.")) {
            collected.append(delta)
        }
        #expect(collected == ["Deep explanation"])
        let body = try JSONSerialization.jsonObject(with: transport.requestBodies[0]) as? [String: Any]
        #expect(body?["model"] as? String == "gpt-5.6-luna")
        #expect(body?["instructions"] as? String == "SYS")
        #expect((body?["input"] as? String)?.contains("<short_answer>\nBecause.\n</short_answer>") == true)
        #expect((body?["input"] as? String)?.contains("<question>\nWhy?\n</question>") == true)
    }

    @Test func missingKeyAndHTTPErrorsMapToProviderErrors() async {
        let noKey = OpenAIResponsesHintExpander(secretStoring: StaticSecret(key: nil), transport: RecordingTransport(response: .success(Data())), modelIDProvider: { "m" }, instructionsProvider: { "" })
        await #expect(throws: AnswerProviderError.missingAPIKey(.openAIRealtime)) {
            for try await _ in noKey.expand(HintExpansionRequest(hintID: UUID(), question: nil, answer: "a")) {}
        }
        let rateLimited = OpenAIResponsesHintExpander(secretStoring: StaticSecret(key: "sk"), transport: RecordingTransport(response: .failure(ResponsesAPITransportError.httpError(statusCode: 429))), modelIDProvider: { "m" }, instructionsProvider: { "" })
        await #expect(throws: AnswerProviderError.rateLimited(retryAfterSeconds: nil)) {
            for try await _ in rateLimited.expand(HintExpansionRequest(hintID: UUID(), question: nil, answer: "a")) {}
        }
        #expect(OpenAIResponsesHintExpander.map(.httpError(statusCode: 404)) == .modelNotFound(""))
        #expect(OpenAIResponsesHintExpander.map(.httpError(statusCode: 503)) == .serverError(status: 503))
    }
}
