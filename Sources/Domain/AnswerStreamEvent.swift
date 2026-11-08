public enum AnswerStreamEvent: Sendable, Equatable {
    case collectingContext
    case manualResponsePending
    case streaming(text: String)
    case completed(finalText: String)
    case cancelled
    case noContext
}
