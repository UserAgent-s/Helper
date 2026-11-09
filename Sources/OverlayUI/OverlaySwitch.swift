import Foundation
import Observation

@MainActor
@Observable
final class OverlaySwitch {
    @ObservationIgnored private let preferences: OverlayPreferencesStore
    @ObservationIgnored private var handlers: [UUID: @MainActor (Bool) -> Void] = [:]

    private(set) var isEnabled: Bool

    init(preferences: OverlayPreferencesStore = OverlayPreferencesStore()) {
        self.preferences = preferences
        isEnabled = preferences.isOverlayEnabled
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        preferences.isOverlayEnabled = enabled
        for handler in handlers.values {
            handler(enabled)
        }
    }

    @discardableResult
    func observe(_ handler: @escaping @MainActor (Bool) -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        handlers[id] = nil
    }
}
