import Testing
@testable import Domain

@Suite struct AudioTransportMappingTests {

    @Test(arguments: [
        ("bltn", AudioTransport.builtIn),
        ("usb ", .usb),
        ("blue", .bluetooth),
        ("blea", .bluetoothLE),
        ("airp", .airPlay),
        ("grup", .aggregate),
        ("virt", .virtual),
        ("ccwd", .continuityWired),
        ("ccwl", .continuityWireless),
    ])
    func knownFourCCsMap(code: String, expected: AudioTransport) {
        #expect(AudioTransport(fourCC: AudioTransport.fourCC(code)) == expected)
    }

    @Test func unknownMapsToOther() {
        let value = AudioTransport.fourCC("zzzz")
        #expect(AudioTransport(fourCC: value) == .other(value))
    }

    @Test func onlyContinuityTransportsAreContinuity() {
        #expect(AudioTransport.continuityWired.isContinuity)
        #expect(AudioTransport.continuityWireless.isContinuity)
        #expect(!AudioTransport.builtIn.isContinuity)
        #expect(!AudioTransport.usb.isContinuity)
    }

    @Test func fourCCMatchesCoreAudioConstant() {
        #expect(AudioTransport.fourCC("bltn") == 0x626C_746E)
    }
}
