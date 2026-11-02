import Domain
import Foundation

public struct AnthropicMessagesAnswerClient: TextAnswerGenerating {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"
    public static let serverSideFallbackBeta = "server-side-fallback-2026-07-01"
    static let maxErrorBodyBytes = 16_384

    private let transport: any AnthropicHTTPTransport
    private let apiKeyProvider: @Sendable () throws -> String?

    public init(
        transport: any AnthropicHTTPTransport = URLSessionAnthropicTransport(),
        apiKeyProvider: @escaping @Sendable () throws -> String?
    ) {
        self.transport = transport
        self.apiKeyProvider = apiKeyProvider
    }

    public func streamAnswer(_ request: TextAnswerRequest) -> AsyncThrowingStream<TextAnswerEvent, Error> {
        let transport = self.transport
        let apiKeyProvider = self.apiKeyProvider
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let apiKey = try? apiKeyProvider(), !apiKey.isEmpty else {
                        throw AnswerProviderError.missingAPIKey(.anthropicClaude)
                    }
                    let urlRequest = try Self.makeURLRequest(request, apiKey: apiKey)
                    let response: AnthropicHTTPResponse
                    do {
                        response = try await transport.send(urlRequest)
                    } catch {
                        throw Self.mapTransportError(error)
                    }
                    guard (200..<300).contains(response.statusCode) else {
                        throw await Self.decodeHTTPError(response)
                    }
                    var parser = ServerSentEventParser()
                    var accumulator = StreamAccumulator()
                    do {
                        for try await line in response.lines {
                            try Task.checkCancellation()
                            guard let event = parser.consume(line: line) else { continue }
                            for output in try accumulator.handle(event) {
                                continuation.yield(output)
                            }
                            if accumulator.isFinished { break }
                        }
                        if let event = parser.finish() {
                            for output in try accumulator.handle(event) {
                                continuation.yield(output)
                            }
                        }
                    } catch let error as AnswerProviderError {
                        throw error
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw Self.mapTransportError(error)
                    }
                    guard accumulator.isFinished else {
                        throw AnswerProviderError.network("stream_ended_without_message_stop")
                    }
                    if let usage = accumulator.usage {
                        continuation.yield(.usage(usage))
                    }
                    if accumulator.stopReason == "refusal", !accumulator.producedText {
                        throw AnswerProviderError.refused
                    }
                    continuation.yield(.completed(stopReason: accumulator.stopReason))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func makeURLRequest(_ request: TextAnswerRequest, apiKey: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        if request.useServerSideFallback {
            urlRequest.setValue(serverSideFallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try JSONEncoder().encode(RequestBody(request))
        return urlRequest
    }

    struct RequestBody: Encodable {
        struct CacheControl: Encodable { let type = "ephemeral" }
        struct SystemBlock: Encodable {
            let type = "text"
            let text: String
            let cacheControl = CacheControl()
            enum CodingKeys: String, CodingKey { case type, text, cacheControl = "cache_control" }
        }
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct OutputConfig: Encodable { let effort: String }

        let model: String
        let maxTokens: Int
        let stream = true
        let system: [SystemBlock]
        let messages: [Message]
        let outputConfig: OutputConfig?
        let fallbacks: String?

        enum CodingKeys: String, CodingKey {
            case model, stream, system, messages, fallbacks
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }

        init(_ request: TextAnswerRequest) {
            model = request.modelID
            maxTokens = request.maxOutputTokens
            system = [SystemBlock(text: request.systemInstructions)]
            messages = [Message(
                role: "user",
                content: AnswerInstructionsBuilder.transcriptUserMessage(
                    transcript: request.transcript,
                    priorExchanges: request.priorExchanges,
                    trigger: request.trigger
                )
            )]
            outputConfig = request.reasoningEffort.map(OutputConfig.init(effort:))
            fallbacks = request.useServerSideFallback ? "default" : nil
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(maxTokens, forKey: .maxTokens)
            try container.encode(stream, forKey: .stream)
            try container.encode(system, forKey: .system)
            try container.encode(messages, forKey: .messages)
            try container.encodeIfPresent(outputConfig, forKey: .outputConfig)
            try container.encodeIfPresent(fallbacks, forKey: .fallbacks)
        }
    }

    static func mapTransportError(_ error: Error) -> AnswerProviderError {
        if let providerError = error as? AnswerProviderError { return providerError }
        if let urlError = error as? URLError {
            return .network("urlerror_\(urlError.code.rawValue)")
        }
        return .network("\(type(of: error))")
    }

    static func decodeHTTPError(_ response: AnthropicHTTPResponse) async -> AnswerProviderError {
        var body = ""
        do {
            for try await line in response.lines {
                body += line + "\n"
                if body.utf8.count > maxErrorBodyBytes { break }
            }
        } catch {}
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: Data(body.utf8))
        let retryAfter = response.headers["retry-after"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return AnswerProviderError.fromAnthropicHTTP(
            status: response.statusCode,
            errorType: envelope?.error.type,
            message: envelope?.error.message,
            retryAfter: retryAfter
        )
    }

    struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let type: String
            let message: String?
        }
        let error: Detail
    }
}

struct StreamAccumulator {
    private(set) var usage: ProviderUsage?
    private(set) var stopReason: String?
    private(set) var isFinished = false
    private(set) var producedText = false

    struct UsagePayload: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    private struct Envelope: Decodable {
        struct MessageObject: Decodable {
            let model: String?
            let usage: UsagePayload?
        }
        struct Block: Decodable {
            struct Hop: Decodable { let model: String? }
            let type: String
            let to: Hop?
        }
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stopReason: String?
            enum CodingKeys: String, CodingKey { case type, text, stopReason = "stop_reason" }
        }
        struct ErrorDetail: Decodable {
            let type: String
            let message: String?
        }
        let type: String
        let message: MessageObject?
        let contentBlock: Block?
        let delta: Delta?
        let usage: UsagePayload?
        let error: ErrorDetail?
        enum CodingKeys: String, CodingKey {
            case type, message, delta, usage, error
            case contentBlock = "content_block"
        }
    }

    mutating func handle(_ event: ServerSentEvent) throws -> [TextAnswerEvent] {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(event.data.utf8)) else {
            return []
        }
        switch envelope.type {
        case "message_start":
            merge(envelope.message?.usage)
            return [.started(servedModel: envelope.message?.model)]
        case "content_block_start":
            if envelope.contentBlock?.type == "fallback", let model = envelope.contentBlock?.to?.model {
                return [.servedByFallback(model: model)]
            }
            return []
        case "content_block_delta":
            if envelope.delta?.type == "text_delta", let text = envelope.delta?.text, !text.isEmpty {
                producedText = true
                return [.textDelta(text)]
            }
            return []
        case "message_delta":
            if let reason = envelope.delta?.stopReason { stopReason = reason }
            merge(envelope.usage)
            return []
        case "message_stop":
            isFinished = true
            return []
        case "error":
            throw AnswerProviderError.fromAnthropicHTTP(
                status: envelope.error?.type == "overloaded_error" ? 529 : 500,
                errorType: envelope.error?.type,
                message: envelope.error?.message,
                retryAfter: nil
            )
        default:
            return []
        }
    }

    private mutating func merge(_ payload: UsagePayload?) {
        guard let payload else { return }
        var current = usage ?? ProviderUsage()
        if let value = payload.inputTokens { current.inputTokens = value }
        if let value = payload.outputTokens { current.outputTokens = value }
        if let value = payload.cacheCreationInputTokens { current.cacheCreationInputTokens = value }
        if let value = payload.cacheReadInputTokens { current.cachedInputTokens = value }
        usage = current
    }
}
