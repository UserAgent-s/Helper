import Domain
import Foundation
import Testing
@testable import Summary

private struct ScriptedResponses: ResponsesAPITransport {
    let result: Result<Data, ResponsesAPITransportError>
    func createResponse(requestBody: Data, apiKey: String) async throws -> Data { try result.get() }
}

@Suite struct OpenAIResponsesTranslatorTests {
    @Test func bodyUsesLunaAndParsesOutputText() async throws {
        let body = try #require(JSONSerialization.jsonObject(with: OpenAIResponsesTranslator.requestBody("Hi", instructions: "x")) as? [String: Any])
        #expect(body["model"] as? String == "gpt-6-luna")
        #expect(body["store"] as? Bool == false)
        let response = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"Привет"}]}]}"#
        let translator = OpenAIResponsesTranslator(transport: ScriptedResponses(result: .success(Data(response.utf8))), secretStoring: FakeSecretStore(apiKey: "sk-x"))
        #expect(await translator.isAvailable())
        #expect(try await translator.translateToRussian("Hi") == "Привет")
    }

    @Test func rateLimitAndMissingKey() async {
        let limited = OpenAIResponsesTranslator(transport: ScriptedResponses(result: .failure(.httpError(statusCode: 429))), secretStoring: FakeSecretStore(apiKey: "sk-x"))
        await #expect(throws: TranslationFailure.rateLimited) { _ = try await limited.translateToRussian("Hi") }
        let none = OpenAIResponsesTranslator(transport: ScriptedResponses(result: .failure(.invalidResponse)), secretStoring: FakeSecretStore(apiKey: nil))
        #expect(await !none.isAvailable())
        await #expect(throws: TranslationFailure.unavailable) { _ = try await none.translateToRussian("Hi") }
    }
}
