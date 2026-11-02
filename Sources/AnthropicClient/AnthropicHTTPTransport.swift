import Foundation

public struct AnthropicHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let lines: AsyncThrowingStream<String, Error>

    public init(statusCode: Int, headers: [String: String], lines: AsyncThrowingStream<String, Error>) {
        self.statusCode = statusCode
        self.headers = headers
        self.lines = lines
    }
}

public protocol AnthropicHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> AnthropicHTTPResponse
}

public final class URLSessionAnthropicTransport: AnthropicHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 120) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> AnthropicHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            if let key = key as? String, let value = value as? String {
                headers[key.lowercased()] = value
            }
        }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(String(decoding: buffer, as: UTF8.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                bytes.task.cancel()
            }
        }
        return AnthropicHTTPResponse(statusCode: http?.statusCode ?? 0, headers: headers, lines: lines)
    }
}
