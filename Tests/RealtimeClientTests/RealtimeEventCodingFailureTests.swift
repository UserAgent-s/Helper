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

@Suite struct RealtimeEventCodingV5Tests {
    @Test func conversationItemAddedDecodes() {
        let json = #"{"type":"conversation.item.added","previous_item_id":null,"item":{"id":"item_1","type":"message","role":"user"}}"#
        #expect(RealtimeServerEventDecoder.decode(Data(json.utf8)) == .conversationItemCreated(itemID: "item_1", previousItemID: nil))
    }

    @Test func responseCreatedWithMetadataDecodes() {
        let json = #"{"type":"response.created","response":{"id":"resp_1","metadata":{"trigger":"manual"}}}"#
        #expect(RealtimeServerEventDecoder.decode(Data(json.utf8)) == .responseCreated(responseID: "resp_1", metadata: ["trigger": "manual"]))
    }

    @Test func responseCreatedWithoutMetadataStillDecodes() {
        let json = #"{"type":"response.created","response":{"id":"resp_2","metadata":null}}"#
        #expect(RealtimeServerEventDecoder.decode(Data(json.utf8)) == .responseCreated(responseID: "resp_2", metadata: nil))
    }

    @Test func systemItemEncodesAsInputTextMessage() throws {
        let event = RealtimeClientEvent.conversationItemCreate(ConversationItemPayload(id: "force_abc", role: .system, text: "FORCE"))
        let data = try JSONEncoder().encode(event)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "conversation.item.create")
        let item = try #require(object["item"] as? [String: Any])
        #expect(item["role"] as? String == "system")
        #expect(item["type"] as? String == "message")
        let content = try #require(item["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "input_text")
        #expect(content.first?["text"] as? String == "FORCE")
    }

    @Test func clearBufferEncodes() throws {
        let data = try JSONEncoder().encode(RealtimeClientEvent.inputAudioBufferClear)
        #expect(String(decoding: data, as: UTF8.self) == #"{"type":"input_audio_buffer.clear"}"#)
    }
}
