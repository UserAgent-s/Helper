import Domain
import Foundation

public struct ClaudeTranslator: TextTranslating {
    public static let rules = """
    Ты переводишь реплики собеседника с живого звонка на русский для владельца. Верни только перевод, без кавычек, пояснений и вариантов. Сохраняй смысл и тон, не сокращай. Технические термины, названия продуктов, API, команды и код (например idempotency key, webhook, chargeback, 3DS, PSP, Kubernetes) оставляй как есть. Если реплика уже на русском, верни её без изменений.
    """

    public let providerID = ClaudeModel.haiku.rawValue
    private let client: ClaudeMessagesClient
    private let hasKey: @Sendable () -> Bool

    public init(client: ClaudeMessagesClient, hasKey: @escaping @Sendable () -> Bool) {
        self.client = client
        self.hasKey = hasKey
    }

    public func isAvailable() async -> Bool {
        hasKey()
    }

    public static func request(_ text: String) -> ClaudeMessagesRequest {
        ClaudeMessagesRequest(
            model: .haiku,
            maxTokens: 512,
            stream: false,
            effort: .low,
            system: [ClaudeSystemBlock(text: rules)],
            messages: [.user(text)],
            serverFallback: false,
            thinking: .disabled
        )
    }

    public func translateToRussian(_ text: String) async throws -> String {
        switch await client.complete(Self.request(text)) {
        case .success(let completion):
            if completion.stopReason == .refusal { throw TranslationFailure.failed("refused") }
            return completion.text
        case .failure(let failure):
            switch failure {
            case .http(429, _, _), .api("rate_limit_error", _): throw TranslationFailure.rateLimited
            case .missingAPIKey: throw TranslationFailure.unavailable
            default: throw TranslationFailure.failed(ClaudeExpansionClient.errorCode(failure))
            }
        }
    }
}
