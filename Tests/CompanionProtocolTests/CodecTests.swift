import CompanionProtocol
import Foundation
import Testing

@Suite struct GoldenFixtureTests {
    @Test(arguments: ServerEvent.knownTypes)
    func serverFixtureDecodesAndEncodesCanonically(type: String) throws {
        let expected = try #require(Expectations.server[type])
        let fixture = try Fixtures.data("server", type)
        let decoded = try CompanionCodec.decodeServer(fixture)
        #expect(decoded == expected)
        #expect(decoded.type == type)
        let encoded = try CompanionCodec.encode(expected)
        #expect(try Fixtures.jsonObject(encoded) == Fixtures.jsonObject(fixture))
    }

    @Test(arguments: ClientCommand.Action.knownNames)
    func clientFixtureDecodesAndEncodesCanonically(name: String) throws {
        let expected = try #require(Expectations.client[name])
        let fixture = try Fixtures.data("client", name)
        let decoded = try CompanionCodec.decodeCommand(fixture)
        #expect(decoded == expected)
        #expect(decoded.name == name)
        let encoded = try CompanionCodec.encode(expected)
        #expect(try Fixtures.jsonObject(encoded) == Fixtures.jsonObject(fixture))
    }

    @Test func everyKnownTypeHasExactlyOneFixture() throws {
        #expect(try Fixtures.names("server") == Set(ServerEvent.knownTypes))
        #expect(try Fixtures.names("client") == Set(ClientCommand.Action.knownNames))
        #expect(Set(Expectations.server.keys) == Set(ServerEvent.knownTypes))
        #expect(Set(Expectations.client.keys) == Set(ClientCommand.Action.knownNames))
    }
}

@Suite struct CodecRoundTripTests {
    @Test func everyServerEventRoundTrips() throws {
        for (_, envelope) in Expectations.server {
            let data = try CompanionCodec.encode(envelope)
            #expect(try CompanionCodec.decodeServer(data) == envelope)
        }
    }

    @Test func everyClientCommandRoundTrips() throws {
        for (_, command) in Expectations.client {
            let data = try CompanionCodec.encode(command)
            #expect(try CompanionCodec.decodeCommand(data) == command)
        }
    }

    @Test func nilOptionalsAreOmittedFromTheWire() throws {
        let data = try CompanionCodec.encode(ServerEnvelope(seq: 1, ts: 5, event: .error(.init(code: "x", fatal: false))))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["sid"] == nil)
        let payload = try #require(object["data"] as? [String: Any])
        #expect(payload["message"] == nil)
    }

    @Test func pongWithoutDataDecodes() throws {
        let json = #"{"v":1,"seq":3,"ts":9,"type":"pong"}"#
        #expect(try CompanionCodec.decodeServer(Data(json.utf8)).event == .pong(.init()))
    }

    @Test func outboundFrameOverLimitIsRejected() {
        let text = String(repeating: "a", count: CompanionLimits.maxOutboundFrameBytes)
        let envelope = ServerEnvelope(seq: 1, ts: 1, event: .answerReplace(.init(answerId: "r", text: text)))
        #expect(throws: CompanionProtocolError.self) { try CompanionCodec.encode(envelope) }
    }

    @Test func nonASCIITextSurvivesUnescaped() throws {
        let data = try CompanionCodec.encode(ServerEnvelope(seq: 1, ts: 1, event: .answerReplace(.init(answerId: "r/1", text: "Привет ⟶ ok"))))
        let raw = try #require(String(data: data, encoding: .utf8))
        #expect(raw.contains("Привет"))
        #expect(raw.contains("r/1"))
    }
}

@Suite struct UnknownTypeToleranceTests {
    @Test func unknownServerTypeDecodesToUnknown() throws {
        let json = #"{"v":1,"seq":7,"ts":1,"type":"future.thing","data":{"anything":[1,2,{"x":null}]}}"#
        let envelope = try CompanionCodec.decodeServer(Data(json.utf8))
        #expect(envelope.event == .unknown(type: "future.thing"))
        #expect(envelope.seq == 7)
    }

    @Test func unknownCommandNameDecodesToUnknown() throws {
        let json = #"{"v":1,"cmdId":"c1","name":"teleport","args":{"where":"mars"}}"#
        let command = try CompanionCodec.decodeCommand(json)
        #expect(command.action == .unknown(name: "teleport"))
    }

    @Test func extraFieldsAreIgnored() throws {
        let json = #"{"v":1,"seq":1,"ts":1,"type":"mode.changed","extra":true,"data":{"mode":"passive","phase":"idle","future":1}}"#
        #expect(try CompanionCodec.decodeServer(Data(json.utf8)).event == .modeChanged(ModeInfo(mode: .passive, phase: .idle)))
    }

    @Test func unsupportedServerVersionIsAVersionError() {
        let json = #"{"v":2,"seq":1,"ts":1,"type":"pong","data":{}}"#
        #expect(throws: CompanionProtocolError.unsupportedVersion(2)) { try CompanionCodec.decodeServer(Data(json.utf8)) }
    }

    @Test func unsupportedCommandVersionIsAVersionError() {
        let json = #"{"v":0,"cmdId":"c1","name":"answer_now"}"#
        #expect(throws: CompanionProtocolError.unsupportedVersion(0)) { try CompanionCodec.decodeCommand(json) }
    }

    @Test(arguments: [
        "not json",
        "[]",
        #"{"v":1,"name":"answer_now"}"#,
        #"{"v":"1","cmdId":"c1","name":"answer_now"}"#,
        #"{"v":1,"cmdId":"c1","name":"set_mode","args":{"mode":"party"}}"#,
        #"{"v":1,"cmdId":"c1","name":"hello"}"#,
    ])
    func malformedCommandsThrowMalformed(json: String) {
        #expect {
            try CompanionCodec.decodeCommand(json)
        } throws: { error in
            guard case CompanionProtocolError.malformed = error else { return false }
            return true
        }
    }

    @Test func knownTypeWithBrokenDataIsMalformedNotUnknown() {
        let json = #"{"v":1,"seq":1,"ts":1,"type":"ack","data":{"ok":true}}"#
        #expect {
            try CompanionCodec.decodeServer(Data(json.utf8))
        } throws: { error in
            guard case CompanionProtocolError.malformed = error else { return false }
            return true
        }
    }
}

@Suite struct ClientCommandValidationTests {
    private func expand(freeText: String) throws -> ClientCommand {
        let args = try String(data: JSONEncoder().encode(["freeText": freeText]), encoding: .utf8)!
        return try CompanionCodec.decodeCommand(#"{"v":1,"cmdId":"c1","name":"expand","args":"# + args + "}")
    }

    @Test func freeTextAtLimitIsAccepted() throws {
        let command = try expand(freeText: String(repeating: "я", count: CompanionLimits.maxFreeTextLength))
        guard case .expand(let args) = command.action else { Issue.record("not expand"); return }
        #expect(args.freeText?.count == CompanionLimits.maxFreeTextLength)
    }

    @Test func freeTextOverLimitIsRejected() {
        #expect(throws: CompanionProtocolError.invalidArgument(field: "freeText", reason: "too_long")) {
            try expand(freeText: String(repeating: "a", count: CompanionLimits.maxFreeTextLength + 1))
        }
    }

    @Test func freeTextLimitCountsUTF16LikeJavaScript() {
        let emoji = String(repeating: "😀", count: CompanionLimits.maxFreeTextLength / 2 + 1)
        #expect(throws: CompanionProtocolError.invalidArgument(field: "freeText", reason: "too_long")) {
            try expand(freeText: emoji)
        }
    }

    @Test func expandNeedsPointOrFreeText() {
        #expect(throws: CompanionProtocolError.invalidArgument(field: "pointId", reason: "required")) {
            try CompanionCodec.decodeCommand(#"{"v":1,"cmdId":"c1","name":"expand","args":{"format":"short"}}"#)
        }
    }

    @Test func blankFreeTextIsRejected() {
        #expect(throws: CompanionProtocolError.invalidArgument(field: "freeText", reason: "empty")) {
            try expand(freeText: "  \n ")
        }
    }

    @Test(arguments: ["", "has space", "slash/inside", String(repeating: "x", count: CompanionLimits.maxCommandIDLength + 1)])
    func invalidCommandIDsAreRejected(cmdId: String) throws {
        let json = String(data: try JSONSerialization.data(withJSONObject: ["v": 1, "cmdId": cmdId, "name": "answer_now"]), encoding: .utf8)!
        #expect(throws: CompanionProtocolError.self) { try CompanionCodec.decodeCommand(json) }
    }

    @Test func helloRejectsEmptyOrOversizedToken() {
        #expect(throws: CompanionProtocolError.invalidArgument(field: "token", reason: "empty")) {
            try CompanionCodec.decodeCommand(#"{"v":1,"cmdId":"c1","name":"hello","args":{"token":"","clientVersion":1}}"#)
        }
        let long = String(repeating: "t", count: CompanionLimits.maxTokenLength + 1)
        #expect(throws: CompanionProtocolError.invalidArgument(field: "token", reason: "too_long")) {
            try CompanionCodec.decodeCommand(#"{"v":1,"cmdId":"c1","name":"hello","args":{"token":"\#(long)","clientVersion":1}}"#)
        }
    }

    @Test func helloRejectsNegativeLastSeq() {
        #expect(throws: CompanionProtocolError.invalidArgument(field: "lastSeq", reason: "negative")) {
            try CompanionCodec.decodeCommand(#"{"v":1,"cmdId":"c1","name":"hello","args":{"token":"t","lastSeq":-1,"clientVersion":1}}"#)
        }
    }

    @Test func pairRejectsOversizedDeviceName() {
        let name = String(repeating: "n", count: CompanionLimits.maxDeviceNameLength + 1)
        #expect(throws: CompanionProtocolError.invalidArgument(field: "deviceName", reason: "too_long")) {
            try CompanionCodec.decodeCommand(#"{"v":1,"cmdId":"c1","name":"pair","args":{"code":"123456","deviceName":"\#(name)"}}"#)
        }
    }

    @Test func inboundFrameOverLimitIsRejectedBeforeParsing() {
        let frame = #"{"v":1,"cmdId":"c1","name":"answer_now"}"# + String(repeating: " ", count: CompanionLimits.maxInboundFrameBytes)
        #expect(throws: CompanionProtocolError.frameTooLarge(bytes: frame.utf8.count, limit: CompanionLimits.maxInboundFrameBytes)) {
            try CompanionCodec.decodeCommand(frame)
        }
    }

    @Test func errorCodesAreStableStrings() {
        #expect(CompanionProtocolError.frameTooLarge(bytes: 1, limit: 0).code == "frame_too_large")
        #expect(CompanionProtocolError.unsupportedVersion(2).code == "unsupported_version")
        #expect(CompanionProtocolError.malformed("x").code == "malformed")
        #expect(CompanionProtocolError.invalidArgument(field: "a", reason: "b").code == "invalid_argument")
    }
}
