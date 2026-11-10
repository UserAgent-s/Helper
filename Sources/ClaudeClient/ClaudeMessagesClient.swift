import Foundation

public struct ClaudePrewarmResult: Sendable, Equatable {
    public let model: String
    public let stopReason: ClaudeStopReason
    public let usage: ClaudeUsage
}

public struct ClaudeMessagesClient: Sendable {
    private let transport: any AnthropicMessagesTransport
    private let apiKey: @Sendable () -> String?
    private let endpoint: URL
    private let redactedLog: @Sendable (String) -> Void

    public init(
        transport: any AnthropicMessagesTransport = URLSessionAnthropicTransport(),
        endpoint: URL = ClaudeModelCatalog.endpoint,
        apiKey: @escaping @Sendable () -> String?,
        redactedLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.transport = transport
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.redactedLog = redactedLog
    }

    public func stream(_ request: ClaudeMessagesRequest) -> AsyncStream<ClaudeStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(request, continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func prewarm(_ request: ClaudeMessagesRequest) async -> Result<ClaudePrewarmResult, ClaudeFailure> {
        var request = request
        request.stream = false
        request.maxTokens = 0
        let urlRequest: URLRequest
        switch makeURLRequest(request) {
        case .success(let built): urlRequest = built
        case .failure(let failure): return .failure(failure)
        }
        do {
            let (status, body) = try await transport.send(urlRequest)
            guard (200..<300).contains(status) else { return .failure(Self.httpFailure(status: status, body: body)) }
            guard let message = try? JSONDecoder().decode(WireMessage.self, from: body) else {
                return .failure(.malformed("prewarm response"))
            }
            var usage = ClaudeUsage()
            if let wire = message.usage { usage.merge(wire) }
            return .success(ClaudePrewarmResult(model: message.model ?? request.model.rawValue, stopReason: ClaudeStopReason(wire: message.stopReason ?? "max_tokens"), usage: usage))
        } catch {
            return .failure(.transport(Self.describe(error)))
        }
    }

    public func complete(_ request: ClaudeMessagesRequest) async -> Result<ClaudeCompletion, ClaudeFailure> {
        var request = request
        request.stream = false
        let urlRequest: URLRequest
        switch makeURLRequest(request) {
        case .success(let built): urlRequest = built
        case .failure(let failure): return .failure(failure)
        }
        do {
            let (status, body) = try await transport.send(urlRequest)
            guard (200..<300).contains(status) else { return .failure(Self.httpFailure(status: status, body: body)) }
            guard let message = try? JSONDecoder().decode(WireMessage.self, from: body) else { return .failure(.malformed("message")) }
            var usage = ClaudeUsage()
            if let wire = message.usage { usage.merge(wire) }
            let text = (message.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined()
            return .success(ClaudeCompletion(messageID: message.id ?? "", model: message.model ?? request.model.rawValue, text: text, stopReason: ClaudeStopReason(wire: message.stopReason ?? "end_turn"), usage: usage))
        } catch {
            return .failure(.transport(Self.describe(error)))
        }
    }

    public func countTokens(_ request: ClaudeMessagesRequest, endpoint: URL = ClaudeModelCatalog.countTokensEndpoint) async -> Result<Int, ClaudeFailure> {
        guard let key = apiKey(), !key.isEmpty else { return .failure(.missingAPIKey) }
        let urlRequest: URLRequest
        do {
            urlRequest = try request.countTokensURLRequest(apiKey: key, endpoint: endpoint)
        } catch let error as ClaudeRequestError {
            return .failure(.invalidRequest(error))
        } catch {
            return .failure(.malformed("request encoding"))
        }
        do {
            let (status, body) = try await transport.send(urlRequest)
            guard (200..<300).contains(status) else { return .failure(Self.httpFailure(status: status, body: body)) }
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let tokens = object["input_tokens"] as? Int else {
                return .failure(.malformed("count_tokens response"))
            }
            return .success(tokens)
        } catch {
            return .failure(.transport(Self.describe(error)))
        }
    }

    private func makeURLRequest(_ request: ClaudeMessagesRequest) -> Result<URLRequest, ClaudeFailure> {
        guard let key = apiKey(), !key.isEmpty else { return .failure(.missingAPIKey) }
        do {
            return .success(try request.urlRequest(apiKey: key, endpoint: endpoint))
        } catch let error as ClaudeRequestError {
            return .failure(.invalidRequest(error))
        } catch {
            return .failure(.malformed("request encoding"))
        }
    }

    private func run(_ request: ClaudeMessagesRequest, _ continuation: AsyncStream<ClaudeStreamEvent>.Continuation) async {
        let urlRequest: URLRequest
        switch makeURLRequest(request) {
        case .success(let built): urlRequest = built
        case .failure(let failure):
            continuation.yield(.failed(failure))
            return
        }
        let response: AnthropicHTTPResponse
        do {
            response = try await transport.open(urlRequest)
        } catch {
            if Task.isCancelled { return }
            continuation.yield(.failed(.transport(Self.describe(error))))
            return
        }
        guard (200..<300).contains(response.status) else {
            var body = ""
            do {
                for try await line in response.lines { body += line }
            } catch {}
            let failure = Self.httpFailure(status: response.status, body: Data(body.utf8))
            redactedLog("claude http \(response.status) \(failure)")
            continuation.yield(.failed(failure))
            return
        }
        var decoder = AnthropicSSEDecoder()
        do {
            for try await line in response.lines {
                for event in decoder.consume(line: line) {
                    continuation.yield(event)
                }
                if decoder.isFinished { return }
            }
        } catch {
            if Task.isCancelled { return }
            continuation.yield(.failed(.transport(Self.describe(error))))
            return
        }
        if Task.isCancelled { return }
        for event in decoder.finish() {
            continuation.yield(event)
        }
    }

    static func describe(_ error: any Error) -> String {
        if let urlError = error as? URLError { return "URLError \(urlError.code.rawValue)" }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    static func httpFailure(status: Int, body: Data) -> ClaudeFailure {
        let parsed = try? JSONDecoder().decode(WireErrorBody.self, from: body)
        return .http(status: status, type: parsed?.error?.type, message: parsed?.error?.message)
    }
}
