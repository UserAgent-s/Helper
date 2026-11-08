import Foundation
import Testing
@testable import RealtimeClient

@Suite struct RealtimeEventCodingFailureTests {

    @Test func malformedJSONDecodesToUnknownRatherThanCrashing() {
        let garbage = Data("{not valid json at all".utf8)
        let event = RealtimeServerEventDecoder.decode(garbage)
        #expect(event == .unknown(type: "undecodable"))
    }

    @Test func validEnvelopeWithUnknownTypeDecodesToUnknownWithType() {
        let json = Data(#"{"type": "some.future.event.type"}"#.utf8)
        let event = RealtimeServerEventDecoder.decode(json)
        #expect(event == .unknown(type: "some.future.event.type"))
    }

    @Test func envelopeMissingRequiredFieldsFallsBackToUnknown() {
        let json = Data(#"{"type": "response.output_text.delta"}"#.utf8)
        let event = RealtimeServerEventDecoder.decode(json)
        #expect(event == .unknown(type: "response.output_text.delta"))
    }
}
