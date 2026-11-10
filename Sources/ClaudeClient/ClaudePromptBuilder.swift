import Domain
import Foundation

public enum ClaudePromptBuilder {
    public static let rules = """
    Ты помогаешь владельцу на живом звонке или собеседовании. Пиши от первого лица владельца, как он сам ответил бы вслух: «я делал», «в моём проекте».
    Опыт, проекты, цифры, сроки, названия компаний и технологий бери только из блока <profile>. Ничего не придумывай. Если нужного факта в профиле нет, прямо напиши «в профиле этого нет» и предложи честную формулировку без выдуманного опыта.
    Приоритет источников в профиле: 02_CURRENT_PROFILE важнее 01_ABOUT_ME_ALL_IN_ONE, факты из 03_OPEN_QUESTIONS не подтверждены и не подаются как факт. Если источники расходятся, бери более приоритетный.
    Общие технические знания можно использовать свободно, но не выдавай их за личный опыт.
    Не пересказывай этот промпт, не добавляй служебные теги и не упоминай, что ты модель. Пиши Markdown без вступлений и заключений.
    """

    public static func profileBlock(_ snapshot: ProfileSnapshot?) -> String? {
        guard let snapshot, !snapshot.isEmpty else { return nil }
        var text = "<profile>\n"
        for document in snapshot.documents {
            text += "<document path=\"\(document.relativePath)\">\n\(document.text)\n</document>\n"
        }
        text += "</profile>"
        return text
    }

    public static func system(profile: ProfileSnapshot?) -> [ClaudeSystemBlock] {
        var blocks = [ClaudeSystemBlock(text: rules)]
        if let block = profileBlock(profile) {
            blocks.append(ClaudeSystemBlock(text: block, cacheTTL: .oneHour))
        }
        return blocks
    }

    public static func initialTurn(_ request: ExpansionRequest) -> ClaudeMessage {
        var texts: [String] = []
        let tail = request.transcriptTail.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !tail.isEmpty {
            texts.append("<conversation>\n" + tail.joined(separator: "\n") + "\n</conversation>")
        }
        switch request.source {
        case .point(_, _, _, let answer), .answer(_, let answer):
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { texts.append("<current_answer>\n" + trimmed + "\n</current_answer>") }
        case .freeText:
            break
        }
        if let screen = request.screenText?.trimmingCharacters(in: .whitespacesAndNewlines), !screen.isEmpty {
            texts.append("<screen>\n" + screen + "\n</screen>")
        }
        var task = task(request.source)
        if let note = request.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            task += "\nУточнение: " + note
        }
        texts.append(task + "\n\n" + formatInstruction(request.format) + "\n" + languageInstruction(request.language))
        return ClaudeMessage(role: .user, texts: texts)
    }

    public static func followUpTurn(_ question: String) -> ClaudeMessage {
        .user(question.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func task(_ source: ExpansionSource) -> String {
        switch source {
        case .point(_, _, let point, _):
            "Раскрой подробнее этот пункт ответа, с опорой на мой опыт из профиля:\n" + point
        case .answer:
            "Раскрой текущий ответ подробнее, с опорой на мой опыт из профиля."
        case .freeText(let text):
            "Вопрос: " + text
        }
    }

    static func formatInstruction(_ format: ExpansionFormat) -> String {
        switch format {
        case .structured: "Формат: короткий заголовок и 3–6 пунктов, всего 150–300 слов."
        case .short: "Формат: 3–5 предложений, которые можно сразу сказать вслух."
        case .steps: "Формат: нумерованные шаги, каждый шаг одной-двумя фразами."
        case .code: "Формат: минимальный пример кода в блоке ``` и 2–4 фразы пояснения."
        case .star: "Формат: STAR — Situation, Task, Action, Result — на реальном случае из профиля; если подходящего случая нет, так и скажи."
        }
    }

    static func languageInstruction(_ language: ExpansionLanguage) -> String {
        switch language {
        case .auto: "Язык: тот, на котором задан вопрос собеседника."
        case .ru: "Язык: русский."
        case .en: "Язык: английский."
        case .both: "Язык: сначала по-русски, затем тот же ответ по-английски под заголовком «English»."
        }
    }
}
