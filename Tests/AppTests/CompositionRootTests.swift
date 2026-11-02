import Foundation
import Testing
import Domain
@testable import MeetingAssistant

@MainActor
func makeIsolatedTestEnvironment() -> AppEnvironment {
    let suffix = "tests-\(UUID().uuidString)"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(suffix, isDirectory: true)
    return AppEnvironment.isolated(root: root, suffix: suffix)
}

@MainActor
@Suite struct CompositionRootTests {
    @Test func startsInPassive() async {
        let root = CompositionRoot(environment: makeIsolatedTestEnvironment())
        #expect(await root.modeCoordinator.currentMode == .passive)
    }

    @Test func isolatedEnvironmentNeverTouchesStandardDefaultsOrRealKeychainNamespace() {
        let environment = makeIsolatedTestEnvironment()
        #expect(environment.isIsolated)
        #expect(environment.defaults != UserDefaults.standard)
        #expect(environment.keychainNamespace != "com.local.MeetingAssistant")
    }

    @Test func passiveStartsNoAnswerProvider() async {
        let root = CompositionRoot(environment: makeIsolatedTestEnvironment())
        #expect(await root.answersRouter.currentProvider == nil)
        #expect(await root.answersRouter.startedProviders.isEmpty)
    }
}

@Suite struct TestHostIsolationTests {
    @Test func testHostNeverUsesRealUserData() {
        let environment = AppEnvironment.current()
        #expect(environment.isIsolated)
        #expect(environment.keychainNamespace != "com.local.MeetingAssistant")
    }
}
