public protocol PreferredAudioSourceStoring: Sendable {
    func preferredApplicationBundleID() async -> String?
    func setPreferredApplicationBundleID(_ bundleID: String?) async
}
