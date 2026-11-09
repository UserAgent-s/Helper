import Foundation
import Testing
@testable import AudioCapture
@testable import Domain

private struct StubCatalog: AudioDeviceCataloging {
    var output: AudioDeviceInfo?

    func devices() -> [AudioDeviceInfo] {
        [AudioDeviceInfo(id: 1, uid: "BuiltInMic", name: "MacBook Pro Microphone", transport: .builtIn, hasInput: true, hasOutput: false)]
    }

    func defaultInputUID() -> String? { "BuiltInMic" }
    func defaultOutputDevice() -> AudioDeviceInfo? { output }
    func changes() -> AsyncStream<AudioDeviceChange> { AsyncStream { $0.finish() } }
}

private let speakers = AudioDeviceInfo(id: 2, uid: "BuiltInSpeaker", name: "MacBook Pro Speakers", transport: .builtIn, hasInput: false, hasOutput: true, outputDataSource: AudioTransport.fourCC("ispk"))
private let airPods = AudioDeviceInfo(id: 3, uid: "AirPods", name: "AirPods Pro", transport: .bluetooth, hasInput: true, hasOutput: true)

@Suite struct MicrophoneOptionsTests {
    @Test func profilesMapToSampleRates() {
        #expect(MicrophoneProfile.me.sampleRate == 24_000)
        #expect(MicrophoneProfile.recording.sampleRate == 16_000)
    }

    @Test func meEnablesVoiceProcessingOnlyWhenEchoIsLikely() {
        #expect(MicrophoneProfile.me.voiceProcessing(route: .builtInSpeakers, policy: .auto))
        #expect(!MicrophoneProfile.me.voiceProcessing(route: .bluetoothHeadphones(name: "AirPods"), policy: .auto))
        #expect(!MicrophoneProfile.me.voiceProcessing(route: .wiredHeadphones, policy: .auto))
        #expect(MicrophoneProfile.me.voiceProcessing(route: .wiredHeadphones, policy: .speakers))
        #expect(!MicrophoneProfile.me.voiceProcessing(route: .builtInSpeakers, policy: .headphones))
    }

    @Test func recordingNeverEnablesVoiceProcessing() {
        for policy in OutputRoutePolicy.allCases {
            #expect(!MicrophoneProfile.recording.voiceProcessing(route: .builtInSpeakers, policy: policy))
        }
    }

    @Test func planUsesDefaultOutputRouteAndProfile() {
        let onSpeakers = MicrophoneDeviceResolver.plan(.systemDefaultExcludingContinuity, catalog: StubCatalog(output: speakers), profile: .me)
        #expect(onSpeakers.options == MicrophoneCaptureOptions(deviceUID: "BuiltInMic", sampleRate: 24_000, voiceProcessing: true))
        let onAirPods = MicrophoneDeviceResolver.plan(.systemDefaultExcludingContinuity, catalog: StubCatalog(output: airPods), profile: .me)
        #expect(onAirPods.options == MicrophoneCaptureOptions(deviceUID: "BuiltInMic", sampleRate: 24_000, voiceProcessing: false))
        let forced = MicrophoneDeviceResolver.plan(.systemDefaultExcludingContinuity, catalog: StubCatalog(output: airPods), profile: .me, routePolicy: .speakers)
        #expect(forced.options.voiceProcessing)
        let recording = MicrophoneDeviceResolver.plan(.systemDefaultExcludingContinuity, catalog: StubCatalog(output: speakers))
        #expect(recording.options == MicrophoneCaptureOptions(deviceUID: "BuiltInMic", sampleRate: 16_000, voiceProcessing: false))
    }

    @Test func voiceProcessingTakesOnlyTheProcessedFirstChannel() {
        let interleaved: [Int16] = [100, 9, 9, 200, -9, -9, 300, 0, 0]
        #expect(MicrophoneFrameConverter.monoSamples(interleaved: interleaved, channelCount: 3, voiceProcessing: true) == [100, 200, 300])
    }

    @Test func withoutVoiceProcessingChannelsAreDownmixed() {
        let interleaved: [Int16] = [100, 300, -200, 200]
        #expect(MicrophoneFrameConverter.monoSamples(interleaved: interleaved, channelCount: 2, voiceProcessing: false) == [200, 0])
        #expect(MicrophoneFrameConverter.monoSamples(interleaved: [1, 2, 3], channelCount: 1, voiceProcessing: true) == [1, 2, 3])
    }

    @Test func convertResamplesNineChannelVoiceProcessingInputTo24kHzMono() {
        let frames = 4_800
        var interleaved = [Int16](repeating: 0, count: frames * 9)
        for index in 0..<frames {
            interleaved[index * 9] = 1_000
            interleaved[index * 9 + 1] = -30_000
        }
        let input = PCMAudioFrame(samples: interleaved, sampleRate: 48_000, channelCount: 9, capturedAt: Date(), source: .microphone)
        let output = MicrophoneFrameConverter.convert(input, options: MicrophoneCaptureOptions(sampleRate: 24_000, voiceProcessing: true))
        #expect(output.sampleRate == 24_000)
        #expect(output.channelCount == 1)
        #expect(output.source == .microphone)
        #expect(output.samples.count == 2_400)
        #expect(output.samples.allSatisfy { $0 == 1_000 })
    }

    @Test func convertDownsamplesRecordingTo16kHz() {
        let input = PCMAudioFrame(samples: [Int16](repeating: 500, count: 4_800), sampleRate: 48_000, channelCount: 1, capturedAt: Date(), source: .microphone)
        let output = MicrophoneFrameConverter.convert(input, options: MicrophoneCaptureOptions(sampleRate: 16_000))
        #expect(output.sampleRate == 16_000)
        #expect(output.samples.count == 1_600)
    }
}
