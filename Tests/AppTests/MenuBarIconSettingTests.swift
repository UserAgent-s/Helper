import Foundation
import Testing
import Domain
@testable import MeetingAssistant

@MainActor
@Suite struct MenuBarIconSettingTests {
    @Test func iconIsShownByDefaultAndChoiceSurvivesRelaunch() {
        let environment = makeIsolatedTestEnvironment()
        let store = AppSettingsStore(defaults: environment.defaults)
        #expect(store.showMenuBarIcon)

        store.showMenuBarIcon = false
        #expect(!AppSettingsStore(defaults: environment.defaults).showMenuBarIcon)

        store.showMenuBarIcon = true
        #expect(AppSettingsStore(defaults: environment.defaults).showMenuBarIcon)
    }

    @Test func statusItemFollowsTheSettingWithoutRestart() async throws {
        let root = CompositionRoot(environment: makeIsolatedTestEnvironment())
        root.settingsStore.showMenuBarIcon = false
        let controller = MenuBarController(
            overlayViewModel: root.answerOverlayViewModel,
            modeViewModel: root.modeViewModel,
            navigationState: root.navigationState,
            settingsStore: root.settingsStore
        )
        #expect(!controller.isStatusItemVisible)

        root.settingsStore.showMenuBarIcon = true
        try await waitUntil { controller.isStatusItemVisible }
        #expect(controller.isStatusItemVisible)

        root.settingsStore.showMenuBarIcon = false
        try await waitUntil { !controller.isStatusItemVisible }
        #expect(!controller.isStatusItemVisible)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
