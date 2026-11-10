import Domain
import Foundation

public struct ClaudeDigestGenerator: RealtimeDigestGenerating {
    public static let rules = """
    Ты готовишь выжимку профиля владельца для голосового ассистента, который подсказывает ответы на живом собеседовании. Ассистент видит только эту выжимку, поэтому в ней должно быть всё, что чаще всего спрашивают.
    Бери факты только из блока <profile>, ничего не добавляй и не обобщай сверх написанного. Приоритет источников: 02_CURRENT_PROFILE, затем 01_ABOUT_ME_ALL_IN_ONE; факты из 03_OPEN_QUESTIONS пометь как неподтверждённые.
    Структура: роль и уровень; стек по группам; ключевые проекты (компания, период, что делал сам, цифры и результат); сильные темы для собеседования; чего в опыте нет или мало. Пиши кратко, пунктами, по-русски, названия технологий как в профиле. Без вступления и заключения.
    """

    private let client: ClaudeMessagesClient
    private let hasKey: @Sendable () -> Bool
    private let model: ClaudeModel

    public init(client: ClaudeMessagesClient, hasKey: @escaping @Sendable () -> Bool, model: ClaudeModel = .sonnet) {
        self.client = client
        self.hasKey = hasKey
        self.model = model
    }

    public func isAvailable() async -> Bool {
        hasKey()
    }

    public func generateDigest(from snapshot: ProfileSnapshot, tokenBudget: Int, attempt: Int) async throws -> String {
        let request = Self.request(snapshot: snapshot, tokenBudget: tokenBudget, attempt: attempt, model: model)
        var text = ""
        for await event in client.stream(request) {
            switch event {
            case .textDelta(let chunk): text += chunk
            case .completed(let completion), .truncated(let completion): return completion.text
            case .refused: throw RealtimeDigestError.generationFailed("refused")
            case .failed(let failure): throw RealtimeDigestError.generationFailed(ClaudeExpansionClient.errorCode(failure))
            case .started, .fallback: break
            }
        }
        if text.isEmpty { throw RealtimeDigestError.generationFailed("empty") }
        return text
    }

    static func request(snapshot: ProfileSnapshot, tokenBudget: Int, attempt: Int, model: ClaudeModel) -> ClaudeMessagesRequest {
        let words = max(200, tokenBudget * (attempt == 1 ? 9 : 6) / 40)
        var task = "Составь выжимку не длиннее \(words) слов."
        if attempt > 1 {
            task += " Предыдущий вариант оказался слишком длинным — сократи сильнее, оставь самое важное."
        }
        var system = [ClaudeSystemBlock(text: rules)]
        if let profile = ClaudePromptBuilder.profileBlock(snapshot) {
            system.append(ClaudeSystemBlock(text: profile, cacheTTL: .oneHour))
        }
        return ClaudeMessagesRequest(model: model, maxTokens: 8_000, effort: .low, system: system, messages: [.user(task)])
    }
}
