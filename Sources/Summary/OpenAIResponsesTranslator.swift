import Domain
import Foundation

public struct OpenAIResponsesTranslator: TextTranslating {
    public static let modelID = "gpt-6-luna"

    public let providerID = OpenAIResponsesTranslator.modelID
    private let transport: any ResponsesAPITransport
    private let secretStoring: any SecretStoring

    public init(transport: any ResponsesAPITransport = URLSessionResponsesAPITransport(), secretStoring: any SecretStoring) {
        self.transport = transport
        self.secretStoring = secretStoring
    }

    public func isAvailable() async -> Bool {
        ((try? secretStoring.retrieveAPIKey(provider: .openAI)) ?? nil)?.isEmpty == false
    }

    public static func requestBody(_ text: String, instructions: String) throws -> Data {
        let object: [String: Any] = [
            "model": modelID,
            "input": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": text],
            ],
            "max_output_tokens": 512,
            "store": false,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public func translateToRussian(_ text: String) async throws -> String {
        guard let key = (try? secretStoring.retrieveAPIKey(provider: .openAI)) ?? nil, !key.isEmpty else {
            throw TranslationFailure.unavailable
        }
        let data: Data
        do {
            data = try await transport.createResponse(requestBody: try Self.requestBody(text, instructions: OpenAIResponsesTranslator.instructions), apiKey: key)
        } catch ResponsesAPITransportError.httpError(statusCode: 429) {
            throw TranslationFailure.rateLimited
        } catch {
            throw TranslationFailure.failed("openai")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TranslationFailure.failed("openai_response") }
        if let text = root["output_text"] as? String { return text }
        for item in root["output"] as? [[String: Any]] ?? [] {
            for content in item["content"] as? [[String: Any]] ?? [] {
                if content["type"] as? String == "output_text", let text = content["text"] as? String { return text }
            }
        }
        throw TranslationFailure.failed("openai_response")
    }

    public static let instructions = "Translate the user's message from a live call into Russian. Return only the translation, no quotes or notes. Keep technical terms, product names, APIs, commands and code as they are. If the message is already Russian, return it unchanged."
}
