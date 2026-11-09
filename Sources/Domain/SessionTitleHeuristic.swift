import Foundation

public enum SessionTitleHeuristic {
    public static let maxQuestionLength = 60

    public static func title(for detail: SessionDetail, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.day, .month, .hour, .minute], from: detail.session.startedAt)
        let ordered = detail.questionAnswers.sorted { ($0.askedAt, $0.id.uuidString) < ($1.askedAt, $1.id.uuidString) }
        for pair in ordered {
            guard let question = normalized(pair.questionText) else { continue }
            return String(format: "%02d.%02d · ", parts.day ?? 0, parts.month ?? 0) + truncated(question)
        }
        return String(format: "Звонок %02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func truncated(_ text: String) -> String {
        guard text.count > maxQuestionLength else { return text }
        let prefix = String(text.prefix(maxQuestionLength))
        let cut = prefix.lastIndex(of: " ").map { String(prefix[..<$0]) } ?? prefix
        let trimmed = cut.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        return (trimmed.isEmpty ? prefix : trimmed) + "…"
    }
}
