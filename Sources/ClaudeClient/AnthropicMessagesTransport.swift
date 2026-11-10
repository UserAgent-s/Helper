import Foundation

public struct AnthropicHTTPResponse: Sendable {
    public let status: Int
    public let lines: AsyncThrowingStream<String, any Error>

    public init(status: Int, lines: AsyncThrowingStream<String, any Error>) {
        self.status = status
        self.lines = lines
    }
}

public protocol AnthropicMessagesTransport: Sendable {
    func open(_ request: URLRequest) async throws -> AnthropicHTTPResponse
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public struct URLSessionAnthropicTransport: AnthropicMessagesTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func open(_ request: URLRequest) async throws -> AnthropicHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let lines = AsyncThrowingStream<String, any Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return AnthropicHTTPResponse(status: status, lines: lines)
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
