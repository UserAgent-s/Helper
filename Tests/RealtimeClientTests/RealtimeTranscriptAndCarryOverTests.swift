import Domain
import Foundation
import Testing
@testable import RealtimeClient

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

@Suite struct RealtimeTranscriptAndCarryOverTests {

    private func makeClient(clock: TestClock = TestClock(), sweepInterval: Duration = .seconds(60)) -> (OpenAIRealtimeAnswerClient, FakeRealtimeWebSocketTransport) {
        let transport = FakeRealtimeWebSocketTransport()
        let client = OpenAIRealtimeAnswerClient(
            transport: transport,
            credentialProviding: FakeCredentialProviding(),
            latencyRecording: RecordingLatencyRecorder(),
            reconnectBaseDelay: .milliseconds(10),
            maxReconnectAttempts: 2,
            sweepInterval: sweepInterval,
            now: { clock.now }
        )
        return (client, transport)
    }

    private func answer(_ transport: FakeRealtimeWebSocketTransport, response: String, item: String, text: String, transcript: String? = nil) {
        transport.emit(.inputAudioBufferCommitted(itemID: item, previousItemID: nil))
        if let transcript {
            transport.emit(.inputAudioTranscriptionCompleted(itemID: item, transcript: transcript, language: "ru"))
        }
        transport.emit(.responseCreated(responseID: response))
        transport.emit(.outputTextDelta(responseID: response, itemID: "out-\(response)", delta: text))
        transport.emit(.outputTextDone(responseID: response, itemID: "out-\(response)", text: text))
        transport.emit(.responseDone(responseID: response, status: "completed", outputItemIDs: ["out-\(response)"]))
    }

    private func carryCreates(_ transport: FakeRealtimeWebSocketTransport) -> [ConversationItemPayload] {
        transport.sentEvents.compactMap { event in
            if case .conversationItemCreate(let payload) = event, payload.id.hasPrefix("carry_") { return payload }
            return nil
        }
    }

    private func deletedIDs(_ transport: FakeRealtimeWebSocketTransport) -> [String] {
        transport.sentEvents.compactMap { event in
            if case .conversationItemDelete(let id) = event { return id }
            return nil
        }
    }

    @Test func sessionUpdateRequestsGPTTranscribeWithLanguages() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")

        guard case .sessionUpdate(let config) = transport.sentEvents.first else {
            Issue.record("expected session.update")
            return
        }
        #expect(config.audio.input.transcription == InputTranscriptionConfig(model: "gpt-transcribe", languages: ["ru", "en"]))
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(json.contains(#""transcription":{"#))
        #expect(json.contains(#""model":"gpt-transcribe""#))
        #expect(!json.contains(#""language":"#))
        #expect(client.capabilities.contains(.inputTranscription))
        await client.stop()
    }

    @Test func inputTranscriptionCarriesProfileKeywordsFetchedAtStart() async throws {
        let transport = FakeRealtimeWebSocketTransport()
        let client = OpenAIRealtimeAnswerClient(
            transport: transport,
            credentialProviding: FakeCredentialProviding(),
            latencyRecording: RecordingLatencyRecorder(),
            transcriptionKeywordsProvider: { ["RedCore", "PHP"] }
        )
        try await client.start(instructions: "test")
        guard case .sessionUpdate(let config) = transport.sentEvents.first else {
            Issue.record("expected session.update")
            return
        }
        #expect(config.audio.input.transcription?.keywords == ["RedCore", "PHP"])
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(json.contains(#""keywords":["RedCore","PHP"]"#))
        await client.stop()
    }

    @Test func committedDeltaCompletedProducesThemTranscript() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        let collector = AnswerEventCollector()
        await collector.start(consuming: client.events())

        transport.emit(.inputAudioBufferCommitted(itemID: "u1", previousItemID: nil))
        transport.emit(.inputAudioTranscriptionDelta(itemID: "u1", delta: "Расскажите"))
        transport.emit(.inputAudioTranscriptionCompleted(itemID: "u1", transcript: " Расскажите про CAP ", language: "ru"))
        await waitUntil { await collector.events.contains(.transcript(TranscriptEvent(speaker: .them, itemID: "u1", text: "Расскажите про CAP", language: "ru", isFinal: true))) }

        let transcripts = await collector.events.compactMap { event -> TranscriptEvent? in
            if case .transcript(let transcript) = event { return transcript }
            return nil
        }
        #expect(transcripts == [
            TranscriptEvent(speaker: .them, itemID: "u1", text: "Расскажите", isFinal: false),
            TranscriptEvent(speaker: .them, itemID: "u1", text: "Расскажите про CAP", language: "ru", isFinal: true),
        ])
        await client.stop()
    }

    @Test func questionContextPrecedesResponseStartedWithCommittedItems() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        let collector = AnswerEventCollector()
        await collector.start(consuming: client.events())

        transport.emit(.inputAudioBufferCommitted(itemID: "u1", previousItemID: nil))
        transport.emit(.inputAudioBufferCommitted(itemID: "u2", previousItemID: "u1"))
        transport.emit(.responseCreated(responseID: "r1"))
        transport.emit(.outputTextDelta(responseID: "r1", itemID: "o1", delta: "Ответ"))
        await waitUntil { await collector.events.contains(.responseStarted(responseID: "r1", trigger: .automatic)) }

        let events = await collector.events
        let contextIndex = events.firstIndex(of: .questionContext(responseID: "r1", itemIDs: ["u1", "u2"]))
        let startedIndex = events.firstIndex(of: .responseStarted(responseID: "r1", trigger: .automatic))
        #expect(contextIndex != nil && startedIndex != nil && contextIndex! < startedIndex!)
        await client.stop()
    }

    @Test func firstAnswerDeltaIsNotHeldForPendingTranscription() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        let collector = AnswerEventCollector()
        await collector.start(consuming: client.events())

        transport.emit(.inputAudioBufferCommitted(itemID: "u1", previousItemID: nil))
        transport.emit(.responseCreated(responseID: "r1"))
        transport.emit(.outputTextDelta(responseID: "r1", itemID: "o1", delta: "Сразу"))
        await waitUntil { await collector.events.contains(.textDelta(responseID: "r1", text: "Сразу")) }

        #expect(await collector.events.contains(.textDelta(responseID: "r1", text: "Сразу")))
        await client.stop()
    }

    @Test func transcriptionFailureDoesNotBlockCleanup() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        let collector = AnswerEventCollector()
        await collector.start(consuming: client.events())

        transport.emit(.inputAudioBufferCommitted(itemID: "u1", previousItemID: nil))
        transport.emit(.inputAudioTranscriptionFailed(itemID: "u1", message: "asr down"))
        answer(transport, response: "r1", item: "u2", text: "Ответ")
        await waitUntil { await collector.events.contains(.completed(responseID: "r1")) }

        let events = await collector.events
        #expect(events.contains(.transcriptFailed(itemID: "u1")))
        #expect(events.contains(.completed(responseID: "r1")))
        #expect(deletedIDs(transport).contains("u1"))
        #expect(deletedIDs(transport).contains("u2"))
        let carry = carryCreates(transport)
        #expect(carry.count == 1)
        #expect(carry.first?.text.contains("Q: (not transcribed)") == true)
        await client.stop()
    }

    @Test func completedAnswerIsCarriedOverWithQuestionText() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")

        answer(transport, response: "r1", item: "u1", text: "Kafka хранит лог партиций.", transcript: "Как устроена Kafka?")
        await waitUntil { carryCreates(transport).count == 1 }

        let carry = carryCreates(transport)
        #expect(carry.count == 1)
        #expect(carry.first?.role == .system)
        #expect(carry.first?.text.hasPrefix(RealtimeInstructions.carryOverPrefix) == true)
        #expect(carry.first?.text.contains("Q: Как устроена Kafka?\nA: Kafka хранит лог партиций.") == true)
        #expect(!deletedIDs(transport).contains(carry.first!.id))
        #expect(await client.carryOverItemIDForTesting == carry.first?.id)
        await client.stop()
    }

    @Test func lateTranscriptAfterCleanupRefreshesCarryOver() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")

        answer(transport, response: "r1", item: "u1", text: "Ответ один")
        await waitUntil { carryCreates(transport).count == 1 }
        let first = carryCreates(transport)
        #expect(first.first?.text.contains("(not transcribed)") == true)

        transport.emit(.inputAudioTranscriptionCompleted(itemID: "u1", transcript: "Поздний вопрос", language: nil))
        await waitUntil { carryCreates(transport).count == 2 }

        let all = carryCreates(transport)
        #expect(all.count == 2)
        #expect(all.last?.text.contains("Q: Поздний вопрос") == true)
        #expect(deletedIDs(transport).contains(first.first!.id))
        await client.stop()
    }

    @Test func carryOverKeepsOnlyLastTwoAnswers() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")

        answer(transport, response: "r1", item: "u1", text: "Ответ один", transcript: "Вопрос один")
        answer(transport, response: "r2", item: "u2", text: "Ответ два", transcript: "Вопрос два")
        answer(transport, response: "r3", item: "u3", text: "Ответ три", transcript: "Вопрос три")
        await waitUntil { carryCreates(transport).last?.text.contains("Вопрос три") == true }

        let latest = carryCreates(transport).last?.text ?? ""
        #expect(!latest.contains("Вопрос один"))
        #expect(latest.contains("Вопрос два"))
        #expect(latest.contains("Вопрос три"))
        #expect(latest.range(of: "Вопрос два")!.lowerBound < latest.range(of: "Вопрос три")!.lowerBound)
        await client.stop()
    }

    @Test func carryOverIsEvictedByTimerAfterMaxAge() async throws {
        let clock = TestClock()
        let (client, transport) = makeClient(clock: clock, sweepInterval: .milliseconds(10))
        try await client.start(instructions: "test")

        answer(transport, response: "r1", item: "u1", text: "Ответ", transcript: "Вопрос")
        await waitUntil { !carryCreates(transport).isEmpty }
        let carryID = try #require(carryCreates(transport).first?.id)

        clock.advance(by: 599)
        try await Task.sleep(for: .milliseconds(40))
        #expect(!deletedIDs(transport).contains(carryID))

        clock.advance(by: 2)
        await waitUntil { deletedIDs(transport).contains(carryID) }
        #expect(deletedIDs(transport).contains(carryID))
        #expect(carryCreates(transport).count == 1)
        #expect(await client.carryOverItemIDForTesting == nil)
        await client.stop()
    }

    @Test func contextWindowIsEvictedByTimerWithoutNewCommit() async throws {
        let clock = TestClock()
        let (client, transport) = makeClient(clock: clock, sweepInterval: .milliseconds(10))
        try await client.start(instructions: "test")

        transport.emit(.inputAudioBufferCommitted(itemID: "old", previousItemID: nil))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!deletedIDs(transport).contains("old"))

        clock.advance(by: 301)
        await waitUntil { deletedIDs(transport).contains("old") }
        #expect(deletedIDs(transport).contains("old"))
        await client.stop()
    }

    @Test func sweepDoesNotEvictWhileResponseInFlight() async throws {
        let clock = TestClock()
        let (client, transport) = makeClient(clock: clock, sweepInterval: .milliseconds(10))
        try await client.start(instructions: "test")

        transport.emit(.inputAudioBufferCommitted(itemID: "u1", previousItemID: nil))
        transport.emit(.responseCreated(responseID: "r1"))
        transport.emit(.outputTextDelta(responseID: "r1", itemID: "o1", delta: "Длинный ответ"))
        try await Task.sleep(for: .milliseconds(20))
        clock.advance(by: 301)
        try await Task.sleep(for: .milliseconds(40))

        #expect(!deletedIDs(transport).contains("u1"))
        await client.stop()
    }

    @Test func reconnectRestoresCarryOver() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")

        answer(transport, response: "r1", item: "u1", text: "Ответ до обрыва", transcript: "Вопрос до обрыва")
        await waitUntil { carryCreates(transport).count == 1 }
        let before = carryCreates(transport)
        #expect(before.count == 1)

        transport.emitClosed(reason: "network_lost")
        await waitUntil { carryCreates(transport).count >= 2 }

        let events = transport.sentEvents
        let lastSessionUpdate = try #require(events.lastIndex { if case .sessionUpdate = $0 { true } else { false } })
        let restored = events[lastSessionUpdate...].compactMap { event -> ConversationItemPayload? in
            if case .conversationItemCreate(let payload) = event, payload.id.hasPrefix("carry_") { return payload }
            return nil
        }
        #expect(lastSessionUpdate > 0)
        #expect(restored.count == 1)
        #expect(restored.first?.text.contains("Q: Вопрос до обрыва\nA: Ответ до обрыва") == true)
        #expect(restored.first?.id != before.first?.id)
        await client.stop()
    }

    @Test func resetContextDropsCarryOver() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")

        answer(transport, response: "r1", item: "u1", text: "Ответ", transcript: "Вопрос")
        await waitUntil { !carryCreates(transport).isEmpty }
        let carryID = try #require(carryCreates(transport).first?.id)

        await client.resetContext()
        #expect(deletedIDs(transport).contains(carryID))
        #expect(await client.carryOverItemIDForTesting == nil)
        await client.stop()
    }

    @Test func carryOverDoesNotCountAsQuestionContext() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")

        answer(transport, response: "r1", item: "u1", text: "Ответ", transcript: "Вопрос")
        await waitUntil { !carryCreates(transport).isEmpty }

        await #expect(throws: RealtimeClientError.noContext) {
            try await client.forceResponse()
        }
        await client.stop()
    }
}

@Suite struct RealtimeTranscriptionDecodingTests {
    @Test func deltaDecodes() {
        let json = #"{"type":"conversation.item.input_audio_transcription.delta","event_id":"e1","item_id":"item_1","content_index":0,"delta":"Hel"}"#
        #expect(RealtimeServerEventDecoder.decode(Data(json.utf8)) == .inputAudioTranscriptionDelta(itemID: "item_1", delta: "Hel"))
    }

    @Test func completedDecodesWithDetectedLanguage() {
        let json = #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"e2","item_id":"item_1","content_index":0,"transcript":"Привет","languages":[{"code":"ru"}],"usage":{"type":"duration","seconds":1.2}}"#
        #expect(RealtimeServerEventDecoder.decode(Data(json.utf8)) == .inputAudioTranscriptionCompleted(itemID: "item_1", transcript: "Привет", language: "ru"))
    }

    @Test func completedWithEmptyLanguagesDecodesWithoutLanguage() {
        let json = #"{"type":"conversation.item.input_audio_transcription.completed","event_id":"e3","item_id":"item_2","content_index":0,"transcript":"ok","languages":[]}"#
        #expect(RealtimeServerEventDecoder.decode(Data(json.utf8)) == .inputAudioTranscriptionCompleted(itemID: "item_2", transcript: "ok", language: nil))
    }

    @Test func failedDecodes() {
        let json = #"{"type":"conversation.item.input_audio_transcription.failed","event_id":"e4","item_id":"item_3","content_index":0,"error":{"type":"transcription_error","code":"audio_unintelligible","message":"bad audio"}}"#
        #expect(RealtimeServerEventDecoder.decode(Data(json.utf8)) == .inputAudioTranscriptionFailed(itemID: "item_3", message: "bad audio"))
    }
}
