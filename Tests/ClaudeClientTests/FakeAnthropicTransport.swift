import Foundation
@testable import ClaudeClient

final class FakeAnthropicTransport: AnthropicMessagesTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let status: Int
    private let lines: [String]
    private let sendBody: Data
    private let failure: (any Error)?
    private let onLine: (@Sendable (Int) async -> Void)?

    init(status: Int = 200, lines: [String] = [], sendBody: Data = Data(), failure: (any Error)? = nil, onLine: (@Sendable (Int) async -> Void)? = nil) {
        self.status = status
        self.lines = lines
        self.sendBody = sendBody
        self.failure = failure
        self.onLine = onLine
    }

    static func fixture(_ name: String, status: Int = 200) throws -> FakeAnthropicTransport {
        FakeAnthropicTransport(status: status, lines: try fixtureLines(name))
    }

    static func fixtureLines(_ name: String) throws -> [String] {
        let url = try require(Bundle.module.url(forResource: name, withExtension: "sse", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func open(_ request: URLRequest) async throws -> AnthropicHTTPResponse {
        lock.withLock { _requests.append(request) }
        if let failure { throw failure }
        let lines = self.lines
        let onLine = self.onLine
        let cursor = Cursor()
        let stream = AsyncThrowingStream<String, any Error> {
            guard let index = cursor.next(limit: lines.count) else { return nil }
            await onLine?(index)
            return lines[index]
        }
        return AnthropicHTTPResponse(status: status, lines: stream)
    }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        lock.withLock { _requests.append(request) }
        if let failure { throw failure }
        return (status, sendBody)
    }
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw FixtureMissing() }
    return value
}

private struct FixtureMissing: Error {}

private final class Cursor: @unchecked Sendable {
    private let lock = NSLock()
    private var position = 0
    func next(limit: Int) -> Int? {
        lock.withLock {
            guard position < limit else { return nil }
            defer { position += 1 }
            return position
        }
    }
}
