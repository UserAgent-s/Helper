import Domain
import Foundation
import Testing
@testable import RealtimeClient

private actor Collector<Element: Sendable> {
    private(set) var items: [Element] = []
    private(set) var finished = false

    func append(_ item: Element) { items.append(item) }
    func finish() { finished = true }
}

private func collect<Element: Sendable>(_ stream: AsyncStream<Element>) -> (Collector<Element>, Task<Void, Never>) {
    let collector = Collector<Element>()
    let task = Task {
        for await item in stream { await collector.append(item) }
        await collector.finish()
    }
    return (collector, task)
}

private func meFrame(samples: Int = 2_400, rate: Int = 24_000) -> PCMAudioFrame {
    PCMAudioFrame(samples: Array(repeating: 100, count: samples), sampleRate: rate, channelCount: 1, capturedAt: Date(), source: .microphone)
}

@Suite struct OpenAIRealtimeTranscriptionClientTests {
    private func makeClient(
        transport: FakeRealtimeWebSocketTransport = FakeRealtimeWebSocketTransport(),
        credentials: FakeCredentialProviding = FakeCredentialProviding(),
        attempts: Int = 3
    ) -> (OpenAIRealtimeTranscriptionClient, FakeRealtimeWebSocketTransport) {
        let client = OpenAIRealtimeTranscriptionClient(
            transport: transport,
            credentialProviding: credentials,
            reconnectBaseDelay: .milliseconds(5),
            maxReconnectDelay: .milliseconds(20),
            maxReconnectAttempts: attempts
        )
        return (client, transport)
    }

    @Test func sessionUsesTranscriptionIntentModelLanguagesAndNoTurnDetection() throws {
        let url = OpenAIRealtimeTranscriptionClient.endpointURL.absoluteString
        #expect(url == "wss://api.openai.com/v1/realtime?intent=transcription")
        let event = RealtimeClientEvent.transcriptionSessionUpdate(TranscriptionSessionConfig(model: "gpt-live-transcribe", rate: 24_000, languages: ["ru", "en"], delay: "low"))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        #expect(json["type"] as? String == "session.update")
        let session = try #require(json["session"] as? [String: Any])
        #expect(session["type"] as? String == "transcription")
        #expect(session["model"] == nil)
        let input = try #require((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        #expect(input.keys.contains("turn_detection"))
        #expect(input["turn_detection"] is NSNull)
        let format = try #require(input["format"] as? [String: Any])
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(transcription["model"] as? String == "gpt-live-transcribe")
        #expect(transcription["languages"] as? [String] == ["ru", "en"])
        #expect(transcription["delay"] as? String == "low")
        #expect(transcription["language"] == nil)
        let commit = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(RealtimeClientEvent.inputAudioBufferCommit)) as? [String: Any])
        #expect(commit as NSDictionary == ["type": "input_audio_buffer.commit"] as NSDictionary)
    }

    @Test func startSendsSessionUpdateAndCommitsOnlyOnVADSignal() async throws {
        let (client, transport) = makeClient()
        _ = try await client.start(languages: ["ru", "en"])
        #expect(transport.sentEventTypes == ["session.update"])
        #expect(transport.lastBearerToken == "test-api-key")
        for _ in 0..<5 { await client.appendAudio(meFrame()) }
        #expect(!transport.sentEventTypes.contains("input_audio_buffer.commit"))
        await client.commitTurn()
        await client.commitTurn()
        #expect(transport.sentEventTypes.filter { $0 == "input_audio_buffer.commit" }.count == 1)
        await client.appendAudio(meFrame(samples: 480))
        await client.commitTurn()
        #expect(transport.sentEventTypes.last == "input_audio_buffer.clear")
        #expect(transport.sentEventTypes.filter { $0 == "input_audio_buffer.commit" }.count == 1)
        await client.stop()
    }

    @Test func framesAtOtherRatesAreNotSent() async throws {
        let (client, transport) = makeClient()
        _ = try await client.start(languages: ["ru"])
        await client.appendAudio(meFrame(rate: 16_000))
        #expect(!transport.sentEventTypes.contains("input_audio_buffer.append"))
        #expect(await client.droppedForeignRateFrameCount == 1)
        await client.stop()
    }

    @Test func deltasAccumulateAndOutOfOrderCompletionsMatchByItemID() async throws {
        let (client, transport) = makeClient()
        let (deltas, task) = collect(try await client.start(languages: ["ru", "en"]))
        transport.emit(.inputAudioBufferCommitted(itemID: "item_1", previousItemID: nil))
        transport.emit(.inputAudioTranscriptionDelta(itemID: "item_1", delta: "Я делал "))
        transport.emit(.inputAudioBufferCommitted(itemID: "item_2", previousItemID: "item_1"))
        transport.emit(.inputAudioTranscriptionDelta(itemID: "item_2", delta: "And then "))
        transport.emit(.inputAudioTranscriptionDelta(itemID: "item_1", delta: "Kafka"))
        transport.emit(.inputAudioTranscriptionCompleted(itemID: "item_2", transcript: "And then we scaled it.", language: nil))
        transport.emit(.inputAudioTranscriptionCompleted(itemID: "item_1", transcript: "Я делал Kafka.", language: nil))
        transport.emit(.inputAudioTranscriptionCompleted(itemID: "item_1", transcript: "дубль", language: nil))
        await waitUntil { await deltas.items.filter(\.isFinal).count == 2 }

        let items = await deltas.items
        #expect(items.filter { !$0.isFinal }.map(\.text) == ["Я делал ", "And then ", "Я делал Kafka"])
        let finals = Dictionary(uniqueKeysWithValues: items.filter(\.isFinal).map { ($0.itemID, $0.text) })
        #expect(finals == ["item_1": "Я делал Kafka.", "item_2": "And then we scaled it."])
        #expect(items.allSatisfy { $0.source == .remote })
        await client.stop()
        await task.value
        #expect(await deltas.finished)
    }

    @Test func failedItemIsFinalizedWithPartialTextAndLateCompletionIgnored() async throws {
        let (client, transport) = makeClient()
        let (deltas, task) = collect(try await client.start(languages: ["ru"]))
        transport.emit(.inputAudioTranscriptionDelta(itemID: "item_9", delta: "обрыв"))
        transport.emit(.inputAudioTranscriptionFailed(itemID: "item_9", message: "audio too short"))
        transport.emit(.inputAudioTranscriptionCompleted(itemID: "item_9", transcript: "поздно", language: nil))
        await waitUntil { await deltas.items.contains(where: \.isFinal) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await deltas.items.filter(\.isFinal).map(\.text) == ["обрыв"])
        await client.stop()
        await task.value
    }

    @Test func dropReconnectsWithBackoffAndLeavesMainSessionUntouched() async throws {
        let mainTransport = FakeRealtimeWebSocketTransport()
        let main = OpenAIRealtimeAnswerClient(transport: mainTransport, credentialProviding: FakeCredentialProviding(), latencyRecording: RecordingLatencyRecorder())
        try await main.start(instructions: "test")
        let mainEventsBefore = mainTransport.sentEvents.count

        let (client, transport) = makeClient()
        let (statuses, statusTask) = collect(client.statusUpdates())
        let (deltas, deltaTask) = collect(try await client.start(languages: ["ru", "en"]))
        transport.emit(.inputAudioTranscriptionDelta(itemID: "item_1", delta: "незаконченная"))
        await waitUntil { await deltas.items.count == 1 }

        transport.emitClosed(reason: "network lost")
        await waitUntil { transport.connectCallCount == 2 && transport.sentEventTypes.filter { $0 == "session.update" }.count == 2 }
        await waitUntil {
            let seen = await statuses.items
            return seen.last == .live && seen.contains(.reconnecting(attempt: 1))
        }

        #expect(await deltas.items.last == TranscriptDelta(itemID: "item_1", text: "незаконченная", isFinal: true, source: .remote))
        await client.appendAudio(meFrame())
        await client.commitTurn()
        #expect(transport.sentEventTypes.suffix(2) == ["input_audio_buffer.append", "input_audio_buffer.commit"])
        transport.emit(.inputAudioTranscriptionCompleted(itemID: "item_2", transcript: "после реконнекта", language: nil))
        await waitUntil { await deltas.items.last?.itemID == "item_2" }

        #expect(mainTransport.connectCallCount == 1)
        #expect(mainTransport.closeCallCount == 0)
        #expect(mainTransport.sentEvents.count == mainEventsBefore)

        await client.stop()
        await main.stop()
        await deltaTask.value
        statusTask.cancel()
    }

    @Test func exhaustedReconnectDegradesToUnavailableAndFinishesStream() async throws {
        let (client, transport) = makeClient(attempts: 2)
        let (statuses, statusTask) = collect(client.statusUpdates())
        let (deltas, deltaTask) = collect(try await client.start(languages: ["ru"]))
        transport.connectError = TransportTestError(message: "offline")
        transport.emitFailed("socket error")
        await deltaTask.value
        #expect(await deltas.finished)
        await waitUntil { await statuses.items.last == .unavailable(reason: "reconnect_exhausted") }
        #expect(await statuses.items.contains(.reconnecting(attempt: 2)))
        #expect(transport.connectCallCount == 3)
        let sentBefore = transport.sentEvents.count
        await client.appendAudio(meFrame())
        await client.commitTurn()
        #expect(transport.sentEvents.count == sentBefore)
        await client.stop()
        statusTask.cancel()
    }

    @Test func startWithoutKeyFailsAndReportsUnavailable() async throws {
        let (client, transport) = makeClient(credentials: FakeCredentialProviding(apiKey: nil))
        let (statuses, statusTask) = collect(client.statusUpdates())
        await #expect(throws: RealtimeClientError.notAuthenticated) { _ = try await client.start(languages: ["ru"]) }
        await waitUntil { await statuses.items.last == .unavailable(reason: "connect_failed") }
        #expect(transport.connectCallCount == 0)
        statusTask.cancel()
    }

    @Test func stopClosesTransportAndReportsStopped() async throws {
        let (client, transport) = makeClient()
        let (statuses, statusTask) = collect(client.statusUpdates())
        _ = try await client.start(languages: ["ru"])
        await client.stop()
        #expect(transport.closeCallCount == 1)
        await waitUntil { await statuses.items.last == .stopped }
        transport.emitClosed(reason: "after stop")
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.connectCallCount == 1)
        statusTask.cancel()
    }
}
