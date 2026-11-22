import Testing
import Foundation
@testable import UserAgent057

private func temporaryPreferences() -> OverlayPreferencesStore {
    let name = "UserAgent057Tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return OverlayPreferencesStore(defaults: defaults)
}

private func settle() async {
    for _ in 0..<5 { await Task.yield() }
}

@MainActor
@Suite(.serialized) struct MenuBarIconSettingTests {
    @Test func iconIsVisibleByDefaultAndChoicePersists() {
        let preferences = temporaryPreferences()
        let iconSwitch = MenuBarIconSwitch(preferences: preferences)
        #expect(iconSwitch.isVisible)

        iconSwitch.setVisible(false)
        #expect(iconSwitch.isVisible == false)
        #expect(preferences.isMenuBarIconVisible == false)
        #expect(MenuBarIconSwitch(preferences: preferences).isVisible == false)

        iconSwitch.setVisible(true)
        #expect(MenuBarIconSwitch(preferences: preferences).isVisible)
    }

    @Test func compositionRootSharesOneSwitchWithSettings() {
        let root = CompositionRoot()
        let original = root.menuBarIconSwitch.isVisible
        defer { root.menuBarIconSwitch.setVisible(original) }

        root.settingsViewModel.menuBarIconVisible = !original
        #expect(root.menuBarIconSwitch.isVisible == !original)
        #expect(root.settingsViewModel.menuBarIconVisible == !original)
    }

    @Test func statusItemFollowsTheSwitchLive() async {
        let root = CompositionRoot()
        let preferences = temporaryPreferences()
        preferences.isMenuBarIconVisible = false
        let iconSwitch = MenuBarIconSwitch(preferences: preferences)
        let controller = MenuBarController(
            overlayViewModel: root.answerOverlayViewModel,
            modeViewModel: root.modeViewModel,
            navigationState: root.navigationState,
            overlaySwitch: OverlaySwitch(preferences: preferences),
            menuBarIconSwitch: iconSwitch
        )
        defer { controller.tearDown() }
        #expect(controller.isStatusItemVisible == false)

        iconSwitch.setVisible(true)
        await settle()
        #expect(controller.isStatusItemVisible)

        iconSwitch.setVisible(false)
        await settle()
        #expect(controller.isStatusItemVisible == false)
    }
}
