import Testing
@testable import Domain

private func output(_ name: String, _ transport: AudioTransport, dataSource: String? = nil) -> AudioDeviceInfo {
    AudioDeviceInfo(id: 80, uid: name, name: name, transport: transport, hasInput: false, hasOutput: true, outputDataSource: dataSource.map(AudioTransport.fourCC))
}

@Suite struct OutputRouteClassifierTests {

    @Test func ispkIsSpeakers() {
        #expect(OutputRouteClassifier.classify(output("MacBook Pro Speakers", .builtIn, dataSource: "ispk")) == .builtInSpeakers)
    }

    @Test func hdpnIsWired() {
        #expect(OutputRouteClassifier.classify(output("MacBook Pro Speakers", .builtIn, dataSource: "hdpn")) == .wiredHeadphones)
    }

    @Test func externalHeadphonesNameIsWired() {
        #expect(OutputRouteClassifier.classify(output("External Headphones", .builtIn)) == .wiredHeadphones)
    }

    @Test func bluetoothIsHeadphones() {
        #expect(OutputRouteClassifier.classify(output("AirPods Pro", .bluetooth)) == .bluetoothHeadphones(name: "AirPods Pro"))
        #expect(OutputRouteClassifier.classify(output("Buds", .bluetoothLE)) == .bluetoothHeadphones(name: "Buds"))
    }

    @Test func usbIsExternal() {
        #expect(OutputRouteClassifier.classify(output("USB DAC", .usb)) == .external(name: "USB DAC"))
    }

    @Test func missingDeviceIsUnknown() {
        #expect(OutputRouteClassifier.classify(nil) == .unknown)
    }

    @Test func airPlayIsEchoRisk() {
        let route = OutputRouteClassifier.classify(output("Living Room", .airPlay))
        #expect(route == .airPlay(name: "Living Room"))
        #expect(OutputRouteClassifier.echoRisk(route, policy: .auto))
        #expect(OutputRouteClassifier.echoRisk(.builtInSpeakers, policy: .auto))
        #expect(!OutputRouteClassifier.echoRisk(.wiredHeadphones, policy: .auto))
        #expect(!OutputRouteClassifier.echoRisk(.bluetoothHeadphones(name: "AirPods"), policy: .auto))
    }

    @Test func policyHeadphonesOverridesEchoRisk() {
        #expect(!OutputRouteClassifier.echoRisk(.builtInSpeakers, policy: .headphones))
        #expect(OutputRouteClassifier.echoRisk(.bluetoothHeadphones(name: "Speaker"), policy: .speakers))
    }
}
