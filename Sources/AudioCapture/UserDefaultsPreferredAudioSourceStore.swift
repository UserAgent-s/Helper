import Domain
import Foundation

public actor UserDefaultsPreferredAudioSourceStore: PreferredAudioSourceStoring {
    public static let legacyBundleIDKey = "com.local.UserAgent057.preferredAudioSourceBundleID"
    public static let systemScopeKey = "com.local.UserAgent057.settings.audio.systemScope"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func decodeScope(from defaults: UserDefaults) -> SystemAudioScope? {
        guard let data = defaults.data(forKey: systemScopeKey) else { return nil }
        return try? JSONDecoder().decode(SystemAudioScope.self, from: data)
    }

    public static func encode(_ scope: SystemAudioScope, into defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(scope) else { return }
        defaults.set(data, forKey: systemScopeKey)
    }

    public func systemAudioScope() async -> SystemAudioScope {
        if let scope = Self.decodeScope(from: defaults) {
            return scope
        }
        guard let legacy = defaults.string(forKey: Self.legacyBundleIDKey), !legacy.isEmpty else {
            return .defaultScope
        }
        return .application(bundleID: legacy, fallbackToWholeSystem: true)
    }

    public func setSystemAudioScope(_ scope: SystemAudioScope) async {
        Self.encode(scope, into: defaults)
    }

    public func preferredApplicationBundleID() async -> String? {
        await systemAudioScope().targetApplicationBundleID
    }

    public func setPreferredApplicationBundleID(_ bundleID: String?) async {
        guard let bundleID, !bundleID.isEmpty else {
            await setSystemAudioScope(.defaultScope)
            return
        }
        await setSystemAudioScope(.application(bundleID: bundleID, fallbackToWholeSystem: true))
    }
}
