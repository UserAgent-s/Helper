import Foundation
import Observation

@MainActor
@Observable
final class MenuBarIconSwitch {
    @ObservationIgnored private let preferences: OverlayPreferencesStore

    private(set) var isVisible: Bool

    init(preferences: OverlayPreferencesStore = OverlayPreferencesStore()) {
        self.preferences = preferences
        isVisible = preferences.isMenuBarIconVisible
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        preferences.isMenuBarIconVisible = visible
    }
}
