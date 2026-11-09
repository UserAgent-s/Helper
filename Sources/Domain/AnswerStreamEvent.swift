public enum AnswerStreamEvent: Sendable, Equatable {
    case collectingContext
    case manualResponsePending
    case streaming(text: String)
    case completed(finalText: String)
    case cancelled
    case noContext
}

public struct AnswerStreamUpdate: Sendable, Equatable {
    public let responseID: String?
    public let trigger: AnswerTriggerKind?
    public let event: AnswerStreamEvent

    public init(responseID: String?, trigger: AnswerTriggerKind?, event: AnswerStreamEvent) {
        self.responseID = responseID
        self.trigger = trigger
        self.event = event
    }
}
