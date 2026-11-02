import Foundation

public struct PriorExchange: Sendable, Equatable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

public struct TextAnswerRequest: Sendable, Equatable {
    public let modelID: String
    public let systemInstructions: String
    public let transcript: String
    public let priorExchanges: [PriorExchange]
    public let trigger: AnswerTriggerKind
    public let maxOutputTokens: Int
    public let reasoningEffort: String?
    public let useServerSideFallback: Bool

    public init(
        modelID: String,
        systemInstructions: String,
        transcript: String,
        priorExchanges: [PriorExchange],
        trigger: AnswerTriggerKind,
        maxOutputTokens: Int,
        reasoningEffort: String?,
        useServerSideFallback: Bool
    ) {
        self.modelID = modelID
        self.systemInstructions = systemInstructions
        self.transcript = transcript
        self.priorExchanges = priorExchanges
        self.trigger = trigger
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEffort = reasoningEffort
        self.useServerSideFallback = useServerSideFallback
    }
}

public enum TextAnswerEvent: Sendable, Equatable {
    case started(servedModel: String?)
    case textDelta(String)
    case servedByFallback(model: String)
    case usage(ProviderUsage)
    case completed(stopReason: String?)
}

public protocol TextAnswerGenerating: Sendable {
    func streamAnswer(_ request: TextAnswerRequest) -> AsyncThrowingStream<TextAnswerEvent, Error>
}

public protocol SpeechFragmentRecognizing: Sendable {
    func prepare() async throws
    func recognize(_ frames: [PCMAudioFrame]) async throws -> String
}

public protocol QuestionReadinessDetecting: Sendable {
    func isReadyToAnswer(accumulatedTranscript: String, lastFragment: String, endedByPause: Bool) -> Bool
}
