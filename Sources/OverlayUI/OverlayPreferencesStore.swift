import Foundation
import CoreGraphics

public enum OverlayPosition: String, CaseIterable, Codable, Sendable {
    case topRight, topCenter, bottomRight, custom
}

final class OverlayPreferencesStore {
    private let defaults: UserDefaults

    private enum Keys {
        static let position = "com.local.UserAgent057.overlay.position"
        static let opacity = "com.local.UserAgent057.overlay.opacity"
        static let fontScale = "com.local.UserAgent057.overlay.fontScale"
        static let customOriginX = "com.local.UserAgent057.overlay.customOriginX"
        static let customOriginY = "com.local.UserAgent057.overlay.customOriginY"
        static let forceAnswerHotKey = "com.local.UserAgent057.overlay.forceAnswerHotKey"
        static let toggleSessionHotKey = "com.local.UserAgent057.session.toggleHotKey"
        static let starLastAnswerHotKey = "com.local.UserAgent057.session.starHotKey"
        static let toggleHotKey = "com.local.UserAgent057.overlay.toggleHotKey"
        static let style = "com.local.UserAgent057.overlay.style"
        static let fontFamily = "com.local.UserAgent057.overlay.fontFamily"
        static let enabled = "com.local.UserAgent057.overlay.enabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isOverlayEnabled: Bool {
        get { defaults.object(forKey: Keys.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    var position: OverlayPosition {
        get { OverlayPosition(rawValue: defaults.string(forKey: Keys.position) ?? "") ?? .topRight }
        set { defaults.set(newValue.rawValue, forKey: Keys.position) }
    }

    var opacity: Double {
        get { defaults.object(forKey: Keys.opacity) as? Double ?? 0.95 }
        set { defaults.set(newValue, forKey: Keys.opacity) }
    }

    var fontScale: Double {
        get { defaults.object(forKey: Keys.fontScale) as? Double ?? 1.0 }
        set { defaults.set(newValue, forKey: Keys.fontScale) }
    }

    var customOrigin: CGPoint? {
        get {
            guard defaults.object(forKey: Keys.customOriginX) != nil else { return nil }
            let x = defaults.double(forKey: Keys.customOriginX)
            let y = defaults.double(forKey: Keys.customOriginY)
            return CGPoint(x: x, y: y)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Keys.customOriginX)
                defaults.removeObject(forKey: Keys.customOriginY)
                return
            }
            defaults.set(newValue.x, forKey: Keys.customOriginX)
            defaults.set(newValue.y, forKey: Keys.customOriginY)
        }
    }

    var style: OverlayStyle {
        get { OverlayStyle(rawValue: defaults.string(forKey: Keys.style) ?? "") ?? .floating }
        set { defaults.set(newValue.rawValue, forKey: Keys.style) }
    }

    var fontFamily: OverlayFontFamily {
        get { OverlayFontFamily(rawValue: defaults.string(forKey: Keys.fontFamily) ?? "") ?? .sans }
        set { defaults.set(newValue.rawValue, forKey: Keys.fontFamily) }
    }

    var forceAnswerHotKey: HotKeyCombo {
        get { decoded(Keys.forceAnswerHotKey) ?? .forceAnswerNowDefault }
        set { encode(newValue, forKey: Keys.forceAnswerHotKey) }
    }

    var toggleOverlayHotKey: HotKeyCombo {
        get { decoded(Keys.toggleHotKey) ?? .toggleOverlayDefault }
        set { encode(newValue, forKey: Keys.toggleHotKey) }
    }

    var toggleSessionHotKey: HotKeyCombo {
        get { decoded(Keys.toggleSessionHotKey) ?? .toggleSessionDefault }
        set { encode(newValue, forKey: Keys.toggleSessionHotKey) }
    }

    var starLastAnswerHotKey: HotKeyCombo {
        get { decoded(Keys.starLastAnswerHotKey) ?? .starLastAnswerDefault }
        set { encode(newValue, forKey: Keys.starLastAnswerHotKey) }
    }

    private func decoded(_ key: String) -> HotKeyCombo? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotKeyCombo.self, from: data)
    }

    private func encode(_ combo: HotKeyCombo, forKey key: String) {
        guard let data = try? JSONEncoder().encode(combo) else { return }
        defaults.set(data, forKey: key)
    }
}
