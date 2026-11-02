import Foundation

public struct HeuristicQuestionReadinessDetector: QuestionReadinessDetecting {
    public let minimumWords: Int

    static let interrogativeCues: [String] = [
        "как", "почему", "зачем", "что такое", "чем отличается", "чем отличаются", "расскажите", "расскажи",
        "объясните", "объясни", "опишите", "опиши", "какой", "какая", "какие", "каким", "какую", "сколько",
        "когда", "где", "можете", "могли бы", "можешь", "что бы вы", "что будете", "что вы", "как бы вы",
        "приведите", "назовите", "спроектируйте", "предложите", "сравните", "ли ",
        "how", "why", "what", "which", "when", "where", "could you", "can you", "would you", "tell me",
        "explain", "describe", "walk me through", "design", "compare", "give me an example",
    ]

    public init(minimumWords: Int = 3) {
        self.minimumWords = minimumWords
    }

    public func isReadyToAnswer(accumulatedTranscript: String, lastFragment: String, endedByPause: Bool) -> Bool {
        guard endedByPause else { return false }
        let words = accumulatedTranscript.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= minimumWords else { return false }
        let trimmed = lastFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        let lowered = " " + trimmed.lowercased() + " "
        return Self.interrogativeCues.contains { cue in
            lowered.contains(" " + cue)
        }
    }
}
