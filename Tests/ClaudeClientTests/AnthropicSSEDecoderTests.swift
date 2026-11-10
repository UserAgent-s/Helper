import Foundation
import Testing
@testable import ClaudeClient

@Suite struct AnthropicSSEDecoderTests {
    private func decode(_ name: String) throws -> [ClaudeStreamEvent] {
        var decoder = AnthropicSSEDecoder()
        var events: [ClaudeStreamEvent] = []
        for line in try FakeAnthropicTransport.fixtureLines(name) {
            events += decoder.consume(line: line)
        }
        events += decoder.finish()
        return events
    }

    @Test func skipsThinkingSignatureAndPingAndStreamsTextBeforeStop() throws {
        let events = try decode("thinking_then_text")
        #expect(events.count == 4)
        guard case .started(let id, let model, let usage) = events[0] else { Issue.record("no start"); return }
        #expect(id == "msg_01")
        #expect(model == "claude-sonnet-5-5")
        #expect(usage.cacheReadInputTokens == 21_000)
        #expect(events[1] == .textDelta("В RedCore я "))
        #expect(events[2] == .textDelta("вёл платежи."))
        guard case .completed(let completion) = events[3] else { Issue.record("no completion"); return }
        #expect(completion.text == "В RedCore я вёл платежи.")
        #expect(completion.stopReason == .endTurn)
        #expect(completion.usage.outputTokens == 87)
        #expect(completion.usage.inputTokens == 120)
        #expect(!events.contains { if case .textDelta(let t) = $0 { t.contains("секрет") } else { false } })
    }

    @Test func errorMidStreamTerminatesAndIgnoresLaterLines() throws {
        let events = try decode("error_midstream")
        #expect(events.last == .failed(.api(type: "overloaded_error", message: "Overloaded")))
        #expect(events.filter { $0.isTerminal }.count == 1)
        #expect(!events.contains(.textDelta("после ошибки")))
        #expect(ClaudeFailure.api(type: "overloaded_error", message: nil).isRetryable)
    }

    @Test func midStreamRefusalCarriesCategoryAndPartial() throws {
        let events = try decode("refusal_midstream")
        guard case .refused(let refusal) = events.last else { Issue.record("no refusal"); return }
        #expect(refusal.category == "cyber")
        #expect(refusal.explanation == "policy")
        #expect(refusal.partialText == "Частичный")
        #expect(events.contains(.textDelta("Частичный")))
    }

    @Test func preOutputRefusalHasNoTextAndNullCategory() throws {
        let events = try decode("refusal_preoutput")
        #expect(events.count == 2)
        guard case .refused(let refusal) = events.last else { Issue.record("no refusal"); return }
        #expect(refusal.category == nil)
        #expect(refusal.partialText.isEmpty)
    }

    @Test func maxTokensIsSeparateTruncatedEvent() throws {
        let events = try decode("max_tokens")
        guard case .truncated(let completion) = events.last else { Issue.record("no truncated"); return }
        #expect(completion.stopReason == .maxTokens)
        #expect(completion.text == "Обрезано на полусл")
        #expect(completion.usage.outputTokens == 64)
    }

    @Test func fallbackBlockIsSurfacedAndTextContinues() throws {
        let events = try decode("fallback_midstream")
        #expect(events.contains(.fallback(fromModel: "claude-sonnet-5-5", toModel: "claude-sonnet-5")))
        guard case .completed(let completion) = events.last else { Issue.record("no completion"); return }
        #expect(completion.text == "Первая часть. Продолжение.")
    }

    @Test func streamWithoutMessageStopIsIncomplete() throws {
        let events = try decode("cut_off")
        #expect(events.last == .failed(.incomplete))
    }

    @Test func toleratesCRLFAndNoSpaceAfterColonAndGarbage() {
        var decoder = AnthropicSSEDecoder()
        #expect(decoder.consume(line: ": comment").isEmpty)
        #expect(decoder.consume(line: "event: message_start\r").isEmpty)
        let start = decoder.consume(line: #"data:{"type":"message_start","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":1}}}"# + "\r")
        #expect(start.count == 1)
        #expect(decoder.consume(line: #"data: {"type":"some_future_event","x":1}"#).isEmpty)
        #expect(decoder.consume(line: "data: {not json").last == .failed(.malformed("undecodable event")))
        #expect(decoder.isFinished)
    }
}
