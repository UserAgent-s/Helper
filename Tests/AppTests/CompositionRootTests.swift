import Testing
import Domain
import RealtimeClient
@testable import UserAgent057

@MainActor
@Suite struct CompositionRootTests {
    @Test func startsInPassive() async {
        let root = CompositionRoot()
        #expect(await root.modeCoordinator.currentMode == .passive)
    }

    @Test func questionAnswerLoggerUsesRealtimeModelID() async {
        let root = CompositionRoot()
        #expect(root.questionAnswerLogger.answerModelID == OpenAIRealtimeAnswerClient.modelID)
    }
}
