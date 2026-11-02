import Foundation

public enum AnswerProviderError: Error, Sendable, Equatable {
    case missingAPIKey(AnswerProvider)
    case authentication
    case billing
    case permission
    case modelNotFound(String)
    case rateLimited(retryAfterSeconds: Int?)
    case overloaded
    case serverError(status: Int)
    case invalidRequest(String)
    case network(String)
    case refused
    case recognitionUnavailable(String)
    case spendLimitReached
    case unknown(String)

    public var isRetryableLater: Bool {
        switch self {
        case .rateLimited, .overloaded, .serverError, .network: true
        default: false
        }
    }

    public var endsSession: Bool {
        switch self {
        case .missingAPIKey, .authentication, .billing, .permission, .modelNotFound, .invalidRequest, .recognitionUnavailable, .spendLimitReached: true
        default: false
        }
    }

    public var diagnosticCode: String {
        switch self {
        case .missingAPIKey: "missing_api_key"
        case .authentication: "authentication"
        case .billing: "billing"
        case .permission: "permission"
        case .modelNotFound: "model_not_found"
        case .rateLimited: "rate_limited"
        case .overloaded: "overloaded"
        case .serverError: "server_error"
        case .invalidRequest: "invalid_request"
        case .network: "network"
        case .refused: "refused"
        case .recognitionUnavailable: "recognition_unavailable"
        case .spendLimitReached: "spend_limit_reached"
        case .unknown: "unknown"
        }
    }

    public static func fromOpenAIRealtimeCode(_ code: String) -> AnswerProviderError {
        switch code {
        case "invalid_api_key", "not_authenticated", "notAuthenticated": .authentication
        case "insufficient_quota", "billing_hard_limit_reached": .billing
        case "rate_limit_exceeded": .rateLimited(retryAfterSeconds: nil)
        case "model_not_found": .modelNotFound("")
        case "reconnect_exhausted": .network("reconnect_exhausted")
        case "server_error": .serverError(status: 500)
        default: .unknown(code)
        }
    }

    public static func fromAnthropicHTTP(status: Int, errorType: String?, message: String?, retryAfter: Int?) -> AnswerProviderError {
        switch (status, errorType) {
        case (401, _), (_, "authentication_error"): return .authentication
        case (402, _), (_, "billing_error"): return .billing
        case (403, _), (_, "permission_error"): return .permission
        case (404, _), (_, "not_found_error"): return .modelNotFound(message ?? "")
        case (429, _), (_, "rate_limit_error"): return .rateLimited(retryAfterSeconds: retryAfter)
        case (529, _), (_, "overloaded_error"): return .overloaded
        case (400, _), (413, _), (_, "invalid_request_error"), (_, "request_too_large"): return .invalidRequest(message ?? "")
        case (500...599, _), (_, "api_error"): return .serverError(status: status)
        default: return .unknown("http_\(status)")
        }
    }
}
