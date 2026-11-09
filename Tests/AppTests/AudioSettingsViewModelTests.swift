import AudioCapture
import Domain
import Foundation
import Testing
@testable import UserAgent057

private struct FixedCatalog: AudioDeviceCataloging {
    let list: [AudioDeviceInfo]
    let output: AudioDeviceInfo?

    func devices() -> [AudioDeviceInfo] { list }
    func defaultInputUID() -> String? { nil }
    func defaultOutputDevice() -> AudioDeviceInfo? { output }
    func changes() -> AsyncStream<AudioDeviceChange> { AsyncStream { $0.finish() } }
}

@MainActor
@Suite struct AudioSettingsViewModelTests {
    private let builtIn = AudioDeviceInfo(id: 1, uid: "BuiltInMic", name: "MacBook Pro Microphone", transport: .builtIn, hasInput: true, hasOutput: false)
    private let iPhone = AudioDeviceInfo(id: 2, uid: "iPhoneMic", name: "iPhone Microphone", transport: .continuityWireless, hasInput: true, hasOutput: false)
    private let speakers = AudioDeviceInfo(id: 3, uid: "Speakers", name: "MacBook Pro Speakers", transport: .builtIn, hasInput: false, hasOutput: true, outputDataSource: AudioTransport.fourCC("ispk"))

    private func makeViewModel(defaults suite: String) -> AudioSettingsViewModel {
        AudioSettingsViewModel(
            store: UserDefaultsPreferredAudioSourceStore(defaults: UserDefaults(suiteName: suite)!),
            catalog: FixedCatalog(list: [iPhone, builtIn, speakers], output: speakers),
            settingsStore: AppSettingsStore(defaults: UserDefaults(suiteName: suite)!),
            runningApplicationsProvider: { [RunningApplicationEntry(name: "Spotify", bundleID: "com.spotify.client"), RunningApplicationEntry(name: "Zoom", bundleID: "us.zoom.xos")] }
        )
    }

    private func freshDefaults() -> String {
        "audio-settings-\(UUID().uuidString)"
    }

    @Test func defaultsToWholeSystem() async {
        let viewModel = makeViewModel(defaults: freshDefaults())
        await viewModel.load()
        #expect(viewModel.sourceMode == .wholeSystem)
        #expect(viewModel.scope == .defaultScope)
    }

    @Test func scopeRoundTripsThroughStore() async {
        let defaults = freshDefaults()
        let first = makeViewModel(defaults: defaults)
        await first.load()
        await first.excludeApplication(bundleID: "com.spotify.client")
        await first.excludeApplication(bundleID: "com.spotify.client")

        let second = makeViewModel(defaults: defaults)
        await second.load()
        #expect(second.scope == .wholeSystem(excludingBundleIDs: ["com.spotify.client"]))
        #expect(second.applicationName(for: "com.spotify.client") == "Spotify")

        await second.removeExclusion(bundleID: "com.spotify.client")
        await second.selectChromePreset()
        let third = makeViewModel(defaults: defaults)
        await third.load()
        #expect(third.sourceMode == .chrome)

        await third.selectApplication(bundleID: "us.zoom.xos")
        await third.load()
        #expect(third.sourceMode == .application)
        #expect(third.selectedApplicationBundleID == "us.zoom.xos")
    }

    @Test func continuityMicrophoneIsListedButDisabled() async {
        let viewModel = makeViewModel(defaults: freshDefaults())
        await viewModel.load()
        #expect(viewModel.microphoneOptions.map(\.uid) == ["BuiltInMic", "iPhoneMic"])
        #expect(viewModel.microphoneOptions.first { $0.uid == "iPhoneMic" }?.isEnabled == false)
        #expect(viewModel.microphoneOptions.first { $0.uid == "BuiltInMic" }?.isEnabled == true)

        await viewModel.selectMicrophone(uid: "iPhoneMic")
        #expect(viewModel.microphoneSelection == .systemDefaultExcludingContinuity)
        await viewModel.selectMicrophone(uid: "BuiltInMic")
        #expect(viewModel.microphoneSelection == .device(uid: "BuiltInMic"))
    }

    @Test func routeAndEchoRiskFollowPolicy() async {
        let viewModel = makeViewModel(defaults: freshDefaults())
        await viewModel.load()
        #expect(viewModel.currentRoute == .builtInSpeakers)
        #expect(viewModel.echoRisk)
        viewModel.outputRoutePolicy = .headphones
        #expect(!viewModel.echoRisk)
    }

    @Test func meterFractionMapsDecibelsAndGoesStale() {
        let now = Date()
        #expect(AudioSettingsViewModel.meterFraction(AudioLevel(kind: .systemAudio, rmsDBFS: -30, peakDBFS: -20, at: now), now: now) == 0.5)
        #expect(AudioSettingsViewModel.meterFraction(AudioLevel(kind: .systemAudio, rmsDBFS: -30, peakDBFS: -20, at: now.addingTimeInterval(-5)), now: now) == 0)
        #expect(AudioSettingsViewModel.meterFraction(nil, now: now) == 0)
    }
}
