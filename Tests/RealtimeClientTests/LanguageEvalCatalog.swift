import Foundation

struct LanguageEvalCase: Sendable {
    let id: String
    let questionText: String
    let expectedLanguage: String
    let notes: String
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
