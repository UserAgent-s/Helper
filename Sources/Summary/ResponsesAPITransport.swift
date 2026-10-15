import Foundation

public enum ResponsesAPITransportError: Error, Sendable, Equatable {
    case httpError(statusCode: Int)
    case invalidResponse
}

public protocol ResponsesAPITransport: Sendable {
    func createResponse(requestBody: Data, apiKey: String) async throws -> Data
}

public struct URLSessionResponsesAPITransport: ResponsesAPITransport {
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    public init() {}

    public func createResponse(requestBody: Data, apiKey: String) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResponsesAPITransportError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ResponsesAPITransportError.httpError(statusCode: httpResponse.statusCode)
        }
        return data
    }
}
