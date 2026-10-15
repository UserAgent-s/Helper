import Testing
@testable import OverlayReducer
import Domain

@Suite struct AnswerOverlayReducerTests {

    @Test func deltaChangesTextImmediatelyBeforeDone() {
        var state = AnswerOverlayState.initial
        state = AnswerOverlayReducer.reduce(state, .modeChanged(.answers))
        state = AnswerOverlayReducer.reduce(state, .answerStream(.streaming(text: "Прямой")))
        #expect(state.visibility == .streaming)
        #expect(state.text == "Прямой")

        state = AnswerOverlayReducer.reduce(state, .answerStream(.streaming(text: "Прямой ответ.")))
        #expect(state.text == "Прямой ответ.")

        #expect(state.visibility == .streaming)
    }

    @Test func sentinelNeverSurfacesAsText() {

        var state = AnswerOverlayReducer.reduce(.initial, .modeChanged(.answers))
        state = AnswerOverlayReducer.reduce(state, .answerStream(.collectingContext))
        #expect(state.text.isEmpty)
        #expect(state.visibility == .collectingContext)
    }

    @Test func capsuleVisibleBeforeFirstAnswer() {
        let state = AnswerOverlayReducer.reduce(.initial, .modeChanged(.answers))
        #expect(state.visibility != .hidden)
        #expect(state.text.isEmpty)
    }

    @Test func manualPendingNoContextAndRaceDoNotFlickerOrDoubleText() {
        var state = AnswerOverlayReducer.reduce(.initial, .modeChanged(.answers))
        state = AnswerOverlayReducer.reduce(state, .answerStream(.manualResponsePending))
        #expect(state.visibility == .manualResponsePending)
        #expect(state.text.isEmpty)

        state = AnswerOverlayReducer.reduce(state, .answerStream(.noContext))
        #expect(state.visibility == .collectingContext)
        #expect(state.text.isEmpty)

        state = AnswerOverlayReducer.reduce(state, .answerStream(.manualResponsePending))
        state = AnswerOverlayReducer.reduce(state, .answerStream(.streaming(text: "Ответ")))
        #expect(state.visibility == .streaming)
        #expect(state.text == "Ответ")
    }

    @Test func cancellationClearsOldAnswer() {
        var state = AnswerOverlayReducer.reduce(.initial, .modeChanged(.answers))
        state = AnswerOverlayReducer.reduce(state, .answerStream(.streaming(text: "Незаконченный ответ")))
        state = AnswerOverlayReducer.reduce(state, .answerStream(.cancelled))
        #expect(state.visibility == .collectingContext)
        #expect(state.text.isEmpty)
    }

    @Test func passiveModeHidesOverlay() {
        var state = AnswerOverlayReducer.reduce(.initial, .modeChanged(.answers))
        state = AnswerOverlayReducer.reduce(state, .answerStream(.streaming(text: "Ответ")))
        state = AnswerOverlayReducer.reduce(state, .modeChanged(.passive))
        #expect(state.visibility == .hidden)
        #expect(state.text.isEmpty)
    }

    @Test func recordingModeCannotOpenOverlay() {
        let state = AnswerOverlayReducer.reduce(.initial, .modeChanged(.recording))
        #expect(state.visibility == .hidden)
    }

    @Test func completedStateHoldsFinalTextForCopy() {
        var state = AnswerOverlayReducer.reduce(.initial, .modeChanged(.answers))
        state = AnswerOverlayReducer.reduce(state, .answerStream(.streaming(text: "Частичный")))
        state = AnswerOverlayReducer.reduce(state, .answerStream(.completed(finalText: "Итоговый ответ.")))
        #expect(state.visibility == .completed)
        #expect(state.text == "Итоговый ответ.")
    }

    @Test func completedAnswerSurvivesANewCollectingContextCycle() {
        var state = AnswerOverlayReducer.reduce(.initial, .modeChanged(.answers))
        state = AnswerOverlayReducer.reduce(state, .answerStream(.completed(finalText: "Ответ")))
        state = AnswerOverlayReducer.reduce(state, .answerStream(.collectingContext))
        #expect(state.visibility == .completed)
        #expect(state.text == "Ответ")
    }

    @Test func onlyContextResetClearsACompletedAnswer() {
        var state = AnswerOverlayReducer.reduce(.initial, .modeChanged(.answers))
        state = AnswerOverlayReducer.reduce(state, .answerStream(.completed(finalText: "Ответ")))
        state = AnswerOverlayReducer.reduce(state, .contextReset)
        #expect(state.visibility == .collectingContext)
        #expect(state.text.isEmpty)
    }
}
