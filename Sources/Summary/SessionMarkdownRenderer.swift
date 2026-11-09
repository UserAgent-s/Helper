import Domain
import Foundation

public struct SessionMarkdownLabels: Sendable, Equatable {
    public let started: String
    public let duration: String
    public let minutesSuffix: String
    public let counts: String
    public let summary: String
    public let marked: String
    public let moment: String
    public let questionsAndAnswers: String
    public let unrecognizedQuestion: String
    public let expansion: String
    public let transcript: String
    public let me: String
    public let them: String
    public let translation: String
    public let screenTexts: String
    public let unknownApplication: String
    public let statusStreaming: String
    public let statusCancelled: String
    public let statusFailed: String
    public let untitled: String

    public static let russian = SessionMarkdownLabels(
        started: "Начало",
        duration: "Длительность",
        minutesSuffix: "мин",
        counts: "Вопросов: %d · Отметок: %d",
        summary: "Саммари",
        marked: "Отмеченное",
        moment: "Момент",
        questionsAndAnswers: "Вопросы и ответы",
        unrecognizedQuestion: "(вопрос не распознан)",
        expansion: "Раскрытие",
        transcript: "Транскрипт",
        me: "Я",
        them: "Собеседник",
        translation: "Перевод",
        screenTexts: "Тексты экрана",
        unknownApplication: "Экран",
        statusStreaming: "не завершён",
        statusCancelled: "прерван",
        statusFailed: "ошибка",
        untitled: "Сессия"
    )

    public static let english = SessionMarkdownLabels(
        started: "Started",
        duration: "Duration",
        minutesSuffix: "min",
        counts: "Questions: %d · Marks: %d",
        summary: "Summary",
        marked: "Marked",
        moment: "Moment",
        questionsAndAnswers: "Questions and answers",
        unrecognizedQuestion: "(question not recognized)",
        expansion: "Expansion",
        transcript: "Transcript",
        me: "Me",
        them: "Them",
        translation: "Translation",
        screenTexts: "Screen texts",
        unknownApplication: "Screen",
        statusStreaming: "incomplete",
        statusCancelled: "cancelled",
        statusFailed: "failed",
        untitled: "Session"
    )
}

public enum SessionMarkdownRenderer {
    public static func render(
        _ detail: SessionDetail,
        summary: MeetingSummary? = nil,
        labels: SessionMarkdownLabels = .russian,
        timeZone: TimeZone = .current
    ) -> String {
        let session = detail.session
        let origin = session.startedAt
        let answers = detail.questionAnswers.sorted { ($0.askedAt, $0.id.uuidString) < ($1.askedAt, $1.id.uuidString) }
        let starred = Set(detail.bookmarks.filter { $0.kind == .star }.compactMap(\.questionAnswerID))
        var blocks: [String] = []

        var header = ["# " + singleLine(session.title ?? labels.untitled), ""]
        header.append("- \(labels.started): \(absolute(origin, timeZone: timeZone))")
        if let ended = session.endedAt {
            let minutes = max(0, Int((ended.timeIntervalSince(origin) / 60).rounded()))
            header.append("- \(labels.duration): \(minutes) \(labels.minutesSuffix)")
        }
        header.append("- " + String(format: labels.counts, answers.count, detail.bookmarks.count))
        blocks.append(header.joined(separator: "\n"))

        if let summary, !summary.renderedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append("## \(labels.summary)\n\n" + demoted(summary.renderedMarkdown))
        }

        let marks = detail.bookmarks.sorted { ($0.markedAt, $0.id) < ($1.markedAt, $1.id) }
        if !marks.isEmpty {
            let lines = marks.map { mark -> String in
                let stamp = "[\(offset(mark.markedAt, from: origin))]"
                switch mark.kind {
                case .star:
                    let question = mark.questionAnswerID.flatMap { id in answers.first { $0.id == id } }
                    let text = question.map { questionText($0, labels: labels) } ?? labels.unrecognizedQuestion
                    return "- ★ \(stamp) \(text)"
                case .moment:
                    let note = mark.note.map { ": " + singleLine($0) } ?? ""
                    return "- ⚑ \(stamp) \(labels.moment)\(note)"
                }
            }
            blocks.append("## \(labels.marked)\n\n" + lines.joined(separator: "\n"))
        }

        if !answers.isEmpty {
            var section = ["## \(labels.questionsAndAnswers)"]
            for (index, pair) in answers.enumerated() {
                var entry = "### \(index + 1). \(questionText(pair, labels: labels))"
                if starred.contains(pair.id) { entry += " ★" }
                entry += "\n\n_\(offset(pair.askedAt, from: origin))_"
                if let status = statusLabel(pair.status, labels: labels) { entry += " · _\(status)_" }
                let answer = pair.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !answer.isEmpty { entry += "\n\n" + answer }
                let expansions = detail.expansions
                    .filter { $0.questionAnswerID == pair.id }
                    .sorted { ($0.requestedAt, $0.id) < ($1.requestedAt, $1.id) }
                for expansion in expansions {
                    let body = expansion.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    entry += "\n\n#### \(labels.expansion) · \(singleLine(expansion.modelID))"
                    if !body.isEmpty { entry += "\n\n" + demoted(body, by: 4) }
                }
                section.append(entry)
            }
            blocks.append(section.joined(separator: "\n\n"))
        }

        if !detail.utterances.isEmpty {
            let lines = detail.utterances.map { utterance -> String in
                let stamp = utterance.capturedAt.map { offset($0, from: origin) } ?? "—"
                let speaker = utterance.speaker == .me ? labels.me : labels.them
                var line = "**[\(stamp)] \(speaker):** \(singleLine(utterance.text))"
                if let translation = utterance.translationText.map(singleLine), !translation.isEmpty {
                    let language = utterance.translationLanguage.map { " (\($0))" } ?? ""
                    line += "  \n_\(labels.translation)\(language):_ \(translation)"
                }
                return line
            }
            blocks.append("## \(labels.transcript)\n\n" + lines.joined(separator: "\n\n"))
        }

        let screens = detail.screenContexts.sorted { ($0.capturedAt, $0.id) < ($1.capturedAt, $1.id) }
        if !screens.isEmpty {
            var section = ["## \(labels.screenTexts)"]
            for screen in screens {
                let source = [screen.application, screen.windowTitle]
                    .compactMap { $0.map(singleLine) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " — ")
                let fence = fence(for: screen.text)
                section.append("### [\(offset(screen.capturedAt, from: origin))] \(source.isEmpty ? labels.unknownApplication : source)\n\n\(fence)text\n\(screen.text)\n\(fence)")
            }
            blocks.append(section.joined(separator: "\n\n"))
        }

        return blocks.joined(separator: "\n\n") + "\n"
    }

    public static func offset(_ date: Date, from origin: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(origin).rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "+%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "+%02d:%02d", minutes, seconds)
    }

    static func absolute(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    static func questionText(_ pair: QuestionAnswerPair, labels: SessionMarkdownLabels) -> String {
        let text = singleLine(pair.questionText ?? "")
        return text.isEmpty ? labels.unrecognizedQuestion : text
    }

    static func statusLabel(_ status: AnswerRecordStatus, labels: SessionMarkdownLabels) -> String? {
        switch status {
        case .completed: nil
        case .answerStreaming: labels.statusStreaming
        case .cancelled: labels.statusCancelled
        case .failed: labels.statusFailed
        }
    }

    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0.isWhitespace }).joined(separator: " ")
    }

    static func demoted(_ markdown: String, by levels: Int = 2) -> String {
        var inFence = false
        return markdown
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .map { line in
                if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
                guard !inFence, line.hasPrefix("#") else { return line }
                let hashes = line.prefix { $0 == "#" }.count
                return String(repeating: "#", count: min(6, hashes + levels)) + line.dropFirst(hashes)
            }
            .joined(separator: "\n")
    }

    static func fence(for text: String) -> String {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}
