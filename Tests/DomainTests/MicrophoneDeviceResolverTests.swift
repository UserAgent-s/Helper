import Testing
@testable import Domain

private let builtIn = AudioDeviceInfo(id: 1, uid: "BuiltInMic", name: "MacBook Pro Microphone", transport: .builtIn, hasInput: true, hasOutput: false)
private let iPhone = AudioDeviceInfo(id: 2, uid: "iPhoneMic", name: "iPhone Microphone", transport: .continuityWireless, hasInput: true, hasOutput: false)
private let usbHeadset = AudioDeviceInfo(id: 3, uid: "USBHeadset", name: "USB Headset", transport: .usb, hasInput: true, hasOutput: true)
private let speakers = AudioDeviceInfo(id: 4, uid: "BuiltInSpeakers", name: "MacBook Pro Speakers", transport: .builtIn, hasInput: false, hasOutput: true)

@Suite struct MicrophoneDeviceResolverTests {

    @Test func continuityDefaultFallsBackToBuiltIn() {
        let result = MicrophoneDeviceResolver.resolve(.systemDefaultExcludingContinuity, devices: [iPhone, usbHeadset, builtIn], defaultInputUID: iPhone.uid)
        #expect(result.device == builtIn)
        #expect(result.notice == .microphoneFellBack(from: iPhone.name, to: builtIn.name, reason: .continuityDefault))
    }

    @Test func nonContinuityDefaultIsUsedSilently() {
        let result = MicrophoneDeviceResolver.resolve(.systemDefaultExcludingContinuity, devices: [builtIn, usbHeadset], defaultInputUID: usbHeadset.uid)
        #expect(result.device == usbHeadset)
        #expect(result.notice == nil)
    }

    @Test func explicitContinuityRejected() {
        let result = MicrophoneDeviceResolver.resolve(.device(uid: iPhone.uid), devices: [iPhone, builtIn], defaultInputUID: builtIn.uid)
        #expect(result.device == builtIn)
        #expect(result.notice == .microphoneFellBack(from: iPhone.name, to: builtIn.name, reason: .continuitySelected))
    }

    @Test func selectedMissingFallsBack() {
        let result = MicrophoneDeviceResolver.resolve(.device(uid: "AirPodsMic"), devices: [builtIn, speakers], defaultInputUID: builtIn.uid)
        #expect(result.device == builtIn)
        #expect(result.notice == .microphoneFellBack(from: "AirPodsMic", to: builtIn.name, reason: .selectedDeviceMissing))
    }

    @Test func usbHeadsetSelectedWhenChosen() {
        let result = MicrophoneDeviceResolver.resolve(.device(uid: usbHeadset.uid), devices: [builtIn, usbHeadset], defaultInputUID: builtIn.uid)
        #expect(result.device == usbHeadset)
        #expect(result.notice == nil)
    }

    @Test func noInputsReturnsNil() {
        let result = MicrophoneDeviceResolver.resolve(.systemDefaultExcludingContinuity, devices: [speakers, iPhone], defaultInputUID: iPhone.uid)
        #expect(result.device == nil)
        #expect(result.notice == nil)
    }
}
