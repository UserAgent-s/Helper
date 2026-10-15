import Domain

public enum AnswerOverlayVisibility: Sendable, Equatable {
    case hidden
    case collectingContext
    case manualResponsePending
    case streaming
    case completed
    case reconnecting
}

public struct AnswerOverlayState: Sendable, Equatable {
    public var visibility: AnswerOverlayVisibility
    public var text: String
    public var lastAnswerText: String?

    public static let initial = AnswerOverlayState(visibility: .hidden, text: "", lastAnswerText: nil)
}

public enum AnswerOverlayAction: Sendable, Equatable {
    case modeChanged(AppMode)
    case answerStream(AnswerStreamEvent)
    case connectionTrouble
    case lastAnswerRequested
    case contextReset
}

public enum AnswerOverlayReducer {
    public static func reduce(_ state: AnswerOverlayState, _ action: AnswerOverlayAction) -> AnswerOverlayState {
        var state = state

        switch action {
        case .modeChanged(let mode):
            if mode != .answers {

                state = .initial
            } else if state.visibility == .hidden {
                state.visibility = .collectingContext
                state.text = ""
            }

        case .answerStream(let event):
            switch event {
            case .collectingContext:
                break
            case .manualResponsePending:
                state.visibility = .manualResponsePending
            case .streaming(let text):
                state.visibility = .streaming
                state.text = text
            case .completed(let finalText):
                state.visibility = .completed
                state.text = finalText
                state.lastAnswerText = finalText
            case .cancelled:
                state.visibility = .collectingContext
                state.text = ""
            case .noContext:

                state.visibility = .collectingContext
            }

        case .connectionTrouble:
            state.visibility = .reconnecting

        case .lastAnswerRequested:
            if let lastAnswerText = state.lastAnswerText, state.visibility == .collectingContext {
                state.visibility = .completed
                state.text = lastAnswerText
            }

        case .contextReset:
            state.visibility = .collectingContext
            state.text = ""
            state.lastAnswerText = nil
        }

        return state
    }
}
