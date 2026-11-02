import Domain
import Foundation

public struct OpenAIResponsesHintExpander: HintExpanding {
    private let secretStoring: any SecretStoring
    private let transport: any ResponsesAPITransport
    private let modelIDProvider: @Sendable () -> String
    private let instructionsProvider: @Sendable () -> String
    private let maxOutputTokens: Int

    public init(
        secretStoring: any SecretStoring,
        transport: any ResponsesAPITransport = URLSessionResponsesAPITransport(),
        modelIDProvider: @escaping @Sendable () -> String,
        instructionsProvider: @escaping @Sendable () -> String,
        maxOutputTokens: Int = 2_048
    ) {
        self.secretStoring = secretStoring
        self.transport = transport
        self.modelIDProvider = modelIDProvider
        self.instructionsProvider = instructionsProvider
        self.maxOutputTokens = maxOutputTokens
    }

    public func expand(_ request: HintExpansionRequest) -> AsyncThrowingStream<String, Error> {
        let secretStoring = self.secretStoring
        let transport = self.transport
        let modelID = modelIDProvider()
        let instructions = instructionsProvider()
        let maxOutputTokens = self.maxOutputTokens
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let apiKey = try? secretStoring.retrieveAPIKey(), !apiKey.isEmpty else {
                        throw AnswerProviderError.missingAPIKey(.openAIRealtime)
                    }
                    let body = try Self.requestBody(
                        modelID: modelID,
                        instructions: instructions,
                        input: AnswerInstructionsBuilder.expansionUserMessage(question: request.question, answer: request.answer),
                        maxOutputTokens: maxOutputTokens
                    )
                    let data: Data
                    do {
                        data = try await transport.createResponse(requestBody: body, apiKey: apiKey)
                    } catch let error as ResponsesAPITransportError {
                        throw Self.map(error)
                    } catch let error as URLError {
                        throw AnswerProviderError.network("urlerror_\(error.code.rawValue)")
                    }
                    let text = try Self.outputText(from: data)
                    try Task.checkCancellation()
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func requestBody(modelID: String, instructions: String, input: String, maxOutputTokens: Int) throws -> Data {
        let object: [String: Any] = [
            "model": modelID,
            "instructions": instructions,
            "input": input,
            "max_output_tokens": maxOutputTokens,
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func outputText(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnswerProviderError.invalidRequest("responses_payload_not_object")
        }
        if let outputText = root["output_text"] as? String, !outputText.isEmpty {
            return outputText
        }
        var parts: [String] = []
        for item in root["output"] as? [[String: Any]] ?? [] {
            guard item["type"] as? String == "message" || item["type"] == nil else { continue }
            for content in item["content"] as? [[String: Any]] ?? [] {
                if let text = content["text"] as? String, !text.isEmpty {
                    parts.append(text)
                }
            }
        }
        guard !parts.isEmpty else {
            throw AnswerProviderError.invalidRequest("responses_payload_without_text")
        }
        return parts.joined(separator: "\n")
    }

    static func map(_ error: ResponsesAPITransportError) -> AnswerProviderError {
        switch error {
        case .invalidResponse:
            return .network("responses_invalid_response")
        case .httpError(let status):
            switch status {
            case 401: return .authentication
            case 402: return .billing
            case 403: return .permission
            case 404: return .modelNotFound("")
            case 429: return .rateLimited(retryAfterSeconds: nil)
            case 400, 422: return .invalidRequest("http_\(status)")
            case 500...: return .serverError(status: status)
            default: return .unknown("http_\(status)")
            }
        }
    }
}
