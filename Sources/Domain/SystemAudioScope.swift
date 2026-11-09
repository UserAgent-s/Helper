public enum SystemAudioScope: Codable, Sendable, Equatable {
    case wholeSystem(excludingBundleIDs: [String])
    case application(bundleID: String, fallbackToWholeSystem: Bool)

    public static let defaultScope = SystemAudioScope.wholeSystem(excludingBundleIDs: [])
    public static let chromeBundleID = "com.google.Chrome"
    public static let chromeOnlyPreset = SystemAudioScope.application(bundleID: chromeBundleID, fallbackToWholeSystem: true)

    public var targetApplicationBundleID: String? {
        switch self {
        case .wholeSystem: nil
        case .application(let bundleID, _): bundleID
        }
    }
}

public enum DeviceRole: String, Codable, Sendable, CaseIterable {
    case primary
    case client
}
