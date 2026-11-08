import Domain
import Foundation

public actor UserDefaultsPreferredAudioSourceStore: PreferredAudioSourceStoring {
    private static let key = "com.local.UserAgent057.preferredAudioSourceBundleID"
    public static let defaultBundleID = "com.google.Chrome"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func preferredApplicationBundleID() async -> String? {
        guard let stored = defaults.string(forKey: Self.key) else {
            return Self.defaultBundleID
        }
        return stored.isEmpty ? nil : stored
    }

    public func setPreferredApplicationBundleID(_ bundleID: String?) async {
        defaults.set(bundleID ?? "", forKey: Self.key)
    }
}
