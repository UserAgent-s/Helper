import Domain
import Foundation

struct LanguageEvalCase: Sendable {
    let id: String
    let questionText: String
    let expectedLanguage: String
    let notes: String
    var context: [InjectedContext] = []
    var expectsWaitSentinel = false
}

enum LanguageEvalCatalog {
    static let cases: [LanguageEvalCase] = [
        LanguageEvalCase(id: "ru-full", questionText: "Как работает garbage collector в Go?", expectedLanguage: "ru", notes: "вопрос полностью на русском"),
        LanguageEvalCase(id: "en-full", questionText: "How does the Go garbage collector work?", expectedLanguage: "en", notes: "вопрос полностью на английском"),
        LanguageEvalCase(id: "ru-with-terms", questionText: "Как event loop обрабатывает backpressure при развёртывании в Kubernetes?", expectedLanguage: "ru", notes: "русский с терминами event loop/backpressure/Kubernetes и фрагментом кода"),
        LanguageEvalCase(id: "en-with-ru-quote", questionText: "Can you explain what he meant by the phrase \"нет ничего более постоянного, чем временное\"?", expectedLanguage: "en", notes: "английский с русской цитатой"),
        LanguageEvalCase(id: "design-tradeoff", questionText: "Would you use a message queue or direct HTTP calls between these two services?", expectedLanguage: "en", notes: "design/comparison, нужен существенный trade-off"),
        LanguageEvalCase(id: "debugging", questionText: "Почему сервис падает с OOM только под нагрузкой?", expectedLanguage: "ru", notes: "debugging, нужны гипотеза, проверка и безопасное действие"),
        LanguageEvalCase(id: "missing-context", questionText: "What's the exact latency budget for this endpoint?", expectedLanguage: "en", notes: "недостающий контекст, нельзя выдумывать факты"),
        LanguageEvalCase(id: "statement-not-question", questionText: "Мы вчера обсуждали миграцию базы данных.", expectedLanguage: "ru", notes: "утверждение без вопроса, ожидает sentinel и сохранение как контекст"),
        LanguageEvalCase(
            id: "owner-experience-only",
            questionText: "",
            expectedLanguage: "ru",
            notes: "владелец рассказывает о своём опыте, вопроса нет: ожидается только ⟦WAIT_FOR_QUESTION⟧",
            context: [.me("Я пять лет делал платёжный сервис на Kafka, мы держали около трёх тысяч сообщений в секунду.")],
            expectsWaitSentinel: true
        ),
        LanguageEvalCase(
            id: "owner-remark-then-question",
            questionText: "А как бы вы делали ребалансировку шардов без простоя?",
            expectedLanguage: "ru",
            notes: "владелец уже объяснил шардирование по user_id: ответ опирается на это и не пересказывает сказанное владельцем",
            context: [.me("Мы шардировали по user_id на шестнадцать шардов через consistent hashing.")]
        ),
        LanguageEvalCase(
            id: "screen-task-question",
            questionText: "Can you walk me through how you'd solve the task on your screen?",
            expectedLanguage: "en",
            notes: "задача видна на экране, вопрос английский: ответ про LRU на английском, текст экрана не считается вопросом",
            context: [.screen(application: "Google Chrome", text: "Реализуйте LRU-кэш с операциями get и put за O(1).")]
        ),
        LanguageEvalCase(
            id: "owner-remark-en-not-answered",
            questionText: "",
            expectedLanguage: "en",
            notes: "реплика владельца на английском с вопросительной интонацией адресована собеседнику: это не вопрос к ассистенту, ожидается sentinel",
            context: [.me("I mostly worked on the ingestion side, does that answer your question?")],
            expectsWaitSentinel: true
        ),
    ]

    static let mixedCase = LanguageEvalCase(
        id: "mixed-main-ru",
        questionText: "Слушай, so basically объясни мне, почему это происходит?",
        expectedLanguage: "ru",
        notes: "смешанный вопрос с явно определённой основной (русской) смысловой частью"
    )
}

struct RubricScore: Sendable, Equatable {
    var languageMatch: Bool
    var directness: Bool
    var technicalCorrectness: Bool
    var seniorJudgment: Bool
    var productionMindset: Bool
    var brevity: Bool

    var passed: Bool {
        languageMatch && directness && technicalCorrectness && seniorJudgment && productionMindset && brevity
    }
}
