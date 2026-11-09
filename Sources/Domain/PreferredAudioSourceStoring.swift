public protocol PreferredAudioSourceStoring: Sendable {
    func preferredApplicationBundleID() async -> String?
    func setPreferredApplicationBundleID(_ bundleID: String?) async
    func systemAudioScope() async -> SystemAudioScope
    func setSystemAudioScope(_ scope: SystemAudioScope) async
    func microphoneSelection() async -> MicrophoneSelection
    func setMicrophoneSelection(_ selection: MicrophoneSelection) async
}
