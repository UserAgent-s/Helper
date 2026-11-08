import Testing
import Domain
@testable import MeetingAssistant

@MainActor
@Suite struct CompositionRootTests {
    @Test func startsInPassive() async {
        let root = CompositionRoot()
        #expect(await root.modeCoordinator.currentMode == .passive)
    }
}
