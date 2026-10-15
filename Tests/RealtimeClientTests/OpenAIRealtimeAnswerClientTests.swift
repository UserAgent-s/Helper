import Foundation
import Testing
@testable import RealtimeClient
import Domain

actor AnswerEventCollector {
    private(set) var events: [RealtimeAnswerEvent] = []

    func start(consuming stream: AsyncStream<RealtimeAnswerEvent>) {
        Task { [weak self] in
            for await event in stream {
                await self?.append(event)
            }
        }
    }

    private func append(_ event: RealtimeAnswerEvent) {
        events.append(event)
    }
}

@Suite struct OpenAIRealtimeAnswerClientTests {

    private func makeClient(
        credentialProviding: FakeCredentialProviding = FakeCredentialProviding(),
        latencyRecording: RecordingLatencyRecorder = RecordingLatencyRecorder(),
        redactedLog: @escaping @Sendable (String) -> Void = { _ in }
    ) -> (OpenAIRealtimeAnswerClient, FakeRealtimeWebSocketTransport) {
        let transport = FakeRealtimeWebSocketTransport()
        let client = OpenAIRealtimeAnswerClient(
            transport: transport,
            credentialProviding: credentialProviding,
            latencyRecording: latencyRecording,
            reconnectBaseDelay: .milliseconds(10),
            maxReconnectAttempts: 2,
            redactedLog: redactedLog
        )
        return (client, transport)
    }

    @Test func sessionUpdateSentBeforeFirstAudioAppend() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test instructions")
        await client.appendAudio(PCMAudioFrame(samples: [1, 2, 3], sampleRate: 24_000, channelCount: 1, capturedAt: Date(), source: .systemAudio))
        try await Task.sleep(for: .milliseconds(20))

        let types = transport.sentEventTypes
        #expect(types.first == "session.update")
        #expect(types.contains("input_audio_buffer.append"))
        #expect(types.firstIndex(of: "session.update")! < types.firstIndex(of: "input_audio_buffer.append")!)
        await client.stop()
    }

    @Test func fullSystemInstructionSentVerbatim() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: RealtimeInstructions.system(for: .standard))
        try await Task.sleep(for: .milliseconds(10))

        guard case .sessionUpdate(let config) = transport.sentEvents.first else {
            Issue.record("expected session.update first")
            return
        }
        #expect(config.instructions == RealtimeInstructions.system(for: .standard))
        await client.stop()
    }

    @Test func firstDeltaPublishedBeforeResponseDone() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        let collector = AnswerEventCollector()
        await collector.start(consuming: client.events())

        transport.emit(.inputAudioBufferCommitted(itemID: "item-1", previousItemID: nil))
        transport.emit(.responseCreated(responseID: "resp-1"))
        transport.emit(.outputTextDelta(responseID: "resp-1", itemID: "out-1", delta: "Прямой ответ."))
        try await Task.sleep(for: .milliseconds(20))

        let eventsBeforeDone = await collector.events
        #expect(eventsBeforeDone.contains(.responseStarted(responseID: "resp-1", trigger: .automatic)))
        #expect(eventsBeforeDone.contains(.textDelta(responseID: "resp-1", text: "Прямой ответ.")))
        #expect(!eventsBeforeDone.contains(.completed(responseID: "resp-1")))

        transport.emit(.outputTextDone(responseID: "resp-1", itemID: "out-1", text: "Прямой ответ."))
        transport.emit(.responseDone(responseID: "resp-1", status: "completed", outputItemIDs: ["out-1"]))
        try await Task.sleep(for: .milliseconds(20))

        let finalEvents = await collector.events
        #expect(finalEvents.contains(.completed(responseID: "resp-1")))
        await client.stop()
    }

    @Test func sentinelSuppressedAndUserItemsPreserved() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        let collector = AnswerEventCollector()
        await collector.start(consuming: client.events())

        transport.emit(.inputAudioBufferCommitted(itemID: "user-1", previousItemID: nil))
        transport.emit(.responseCreated(responseID: "resp-1"))
        transport.emit(.outputTextDelta(responseID: "resp-1", itemID: "out-1", delta: RealtimeInstructions.waitForQuestionSentinel))
        transport.emit(.outputTextDone(responseID: "resp-1", itemID: "out-1", text: RealtimeInstructions.waitForQuestionSentinel))
        transport.emit(.responseDone(responseID: "resp-1", status: "completed", outputItemIDs: ["out-1"]))
        try await Task.sleep(for: .milliseconds(20))

        let events = await collector.events
        #expect(events.contains(.waitingForQuestion))
        #expect(!events.contains { if case .responseStarted = $0 { true } else { false } })
        #expect(!events.contains { if case .textDelta = $0 { true } else { false } })

        let deletedIDs: [String] = transport.sentEvents.compactMap {
            if case .conversationItemDelete(let id) = $0 { id } else { nil }
        }
        #expect(deletedIDs == ["out-1"])
        #expect(!deletedIDs.contains("user-1"))

        await client.stop()
    }

    @Test func multipleContextTurnsResolveToOneAnswer() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        let collector = AnswerEventCollector()
        await collector.start(consuming: client.events())

        for i in 1...3 {
            transport.emit(.inputAudioBufferCommitted(itemID: "user-\(i)", previousItemID: nil))
            transport.emit(.responseCreated(responseID: "classify-\(i)"))
            transport.emit(.outputTextDone(responseID: "classify-\(i)", itemID: "out-classify-\(i)", text: RealtimeInstructions.waitForQuestionSentinel))
            transport.emit(.responseDone(responseID: "classify-\(i)", status: "completed", outputItemIDs: ["out-classify-\(i)"]))
        }

        transport.emit(.inputAudioBufferCommitted(itemID: "user-4", previousItemID: nil))
        transport.emit(.responseCreated(responseID: "answer-1"))
        transport.emit(.outputTextDelta(responseID: "answer-1", itemID: "out-answer", delta: "Ответ по всему контексту."))
        transport.emit(.outputTextDone(responseID: "answer-1", itemID: "out-answer", text: "Ответ по всему контексту."))
        transport.emit(.responseDone(responseID: "answer-1", status: "completed", outputItemIDs: ["out-answer"]))
        try await Task.sleep(for: .milliseconds(30))

        let events = await collector.events
        let started = events.filter { if case .responseStarted = $0 { true } else { false } }
        #expect(started.count == 1)
        #expect(events.contains(.responseStarted(responseID: "answer-1", trigger: .automatic)))

        await client.stop()
    }

    @Test func forceAnswerNowSendsExactlyOneResponseCreateWithScopedInstructions() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        transport.emit(.inputAudioBufferCommitted(itemID: "user-1", previousItemID: nil))
        try await Task.sleep(for: .milliseconds(10))

        try await client.forceResponse()
        try await Task.sleep(for: .milliseconds(10))

        let createEvents = transport.sentEvents.compactMap { event -> ResponseCreateOptions? in
            if case .responseCreate(let options) = event { options } else { nil }
        }
        #expect(createEvents.count == 1)
        #expect(createEvents.first?.instructions == RealtimeInstructions.forceAnswerNow)
        #expect(createEvents.first?.metadata?["trigger"] == "manual")

        await client.stop()
    }

    @Test func noAPICallWhenContextEmpty() async throws {
        let (client, _) = makeClient()
        try await client.start(instructions: "test")

        await #expect(throws: RealtimeClientError.noContext) {
            try await client.forceResponse()
        }
        await client.stop()
    }

    @Test func forceResponseDeferredUntilInFlightSpeechCommits() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")

        transport.emit(.speechStarted(itemID: "user-1", audioStartMs: 0))
        try await Task.sleep(for: .milliseconds(10))

        try await client.forceResponse()
        try await Task.sleep(for: .milliseconds(10))
        #expect(!transport.sentEvents.contains { if case .responseCreate = $0 { true } else { false } })

        transport.emit(.speechStopped(itemID: "user-1", audioEndMs: 500))
        transport.emit(.inputAudioBufferCommitted(itemID: "user-1", previousItemID: nil))
        try await Task.sleep(for: .milliseconds(10))

        let createCount = transport.sentEvents.filter { if case .responseCreate = $0 { true } else { false } }.count
        #expect(createCount == 1)
        await client.stop()
    }

    @Test func manualTriggerHasNoEffectAfterStop() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        transport.emit(.inputAudioBufferCommitted(itemID: "user-1", previousItemID: nil))
        try await Task.sleep(for: .milliseconds(10))
        try await client.forceResponse()
        try await Task.sleep(for: .milliseconds(10))
        #expect(transport.sentEvents.contains { if case .responseCreate = $0 { true } else { false } })

        await client.stop()

        let collector = AnswerEventCollector()
        await collector.start(consuming: client.events())

        transport.emit(.responseCreated(responseID: "manual-late"))
        transport.emit(.outputTextDelta(responseID: "manual-late", itemID: "out", delta: "Поздно."))
        try await Task.sleep(for: .milliseconds(20))

        let events = await collector.events
        #expect(events.isEmpty)
    }

    @Test func repeatedClicksDoNotCreateSecondResponse() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        transport.emit(.inputAudioBufferCommitted(itemID: "user-1", previousItemID: nil))
        try await Task.sleep(for: .milliseconds(10))

        try await client.forceResponse()
        try await client.forceResponse()
        try await client.forceResponse()
        try await Task.sleep(for: .milliseconds(10))

        let createCount = transport.sentEvents.filter { if case .responseCreate = $0 { true } else { false } }.count
        #expect(createCount == 1)
        await client.stop()
    }

    @Test func manualTriggerRaceWithAutomaticProducesOneVisibleAnswer() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        let collector = AnswerEventCollector()
        await collector.start(consuming: client.events())

        transport.emit(.inputAudioBufferCommitted(itemID: "user-1", previousItemID: nil))

        transport.emit(.responseCreated(responseID: "auto-1"))
        try await Task.sleep(for: .milliseconds(10))

        try await client.forceResponse()
        try await Task.sleep(for: .milliseconds(10))
        #expect(transport.sentEvents.contains { if case .responseCancel = $0 { true } else { false } })

        transport.emit(.responseDone(responseID: "auto-1", status: "cancelled", outputItemIDs: []))
        transport.emit(.responseCreated(responseID: "manual-1"))
        transport.emit(.outputTextDelta(responseID: "manual-1", itemID: "out-manual", delta: "Ручной ответ."))
        transport.emit(.outputTextDone(responseID: "manual-1", itemID: "out-manual", text: "Ручной ответ."))
        transport.emit(.responseDone(responseID: "manual-1", status: "completed", outputItemIDs: ["out-manual"]))
        try await Task.sleep(for: .milliseconds(20))

        let events = await collector.events
        let started = events.filter { if case .responseStarted = $0 { true } else { false } }
        #expect(started.count == 1)
        #expect(events.contains(.responseStarted(responseID: "manual-1", trigger: .manual)))

        await client.stop()
    }

    @Test func newSpeechCancelsVisibleAnswerAndClearsContext() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        let collector = AnswerEventCollector()
        await collector.start(consuming: client.events())

        transport.emit(.inputAudioBufferCommitted(itemID: "user-1", previousItemID: nil))
        transport.emit(.responseCreated(responseID: "resp-1"))
        transport.emit(.outputTextDelta(responseID: "resp-1", itemID: "out-1", delta: "Начало ответа"))
        try await Task.sleep(for: .milliseconds(10))

        transport.emit(.responseDone(responseID: "resp-1", status: "cancelled", outputItemIDs: ["out-1"]))
        try await Task.sleep(for: .milliseconds(20))

        let events = await collector.events
        #expect(events.contains(.cancelled(responseID: "resp-1", reason: "interrupted_by_speech")))
        #expect(!events.contains(.completed(responseID: "resp-1")))

        let deletedIDs: [String] = transport.sentEvents.compactMap {
            if case .conversationItemDelete(let id) = $0 { id } else { nil }
        }
        #expect(deletedIDs.contains("user-1"))

        await client.stop()
    }

    @Test func contextFullyClearedAfterVisibleAnswerCompletes() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")

        transport.emit(.inputAudioBufferCommitted(itemID: "user-1", previousItemID: nil))
        transport.emit(.inputAudioBufferCommitted(itemID: "user-2", previousItemID: "user-1"))
        transport.emit(.responseCreated(responseID: "resp-1"))
        transport.emit(.outputTextDelta(responseID: "resp-1", itemID: "out-1", delta: "Ответ."))
        transport.emit(.outputTextDone(responseID: "resp-1", itemID: "out-1", text: "Ответ."))
        transport.emit(.responseDone(responseID: "resp-1", status: "completed", outputItemIDs: ["out-1"]))
        try await Task.sleep(for: .milliseconds(20))

        let deletedIDs: Set<String> = Set(transport.sentEvents.compactMap {
            if case .conversationItemDelete(let id) = $0 { id } else { nil }
        })
        #expect(deletedIDs == ["user-1", "user-2", "out-1"])

        await client.stop()
    }

    @Test func reconnectDoesNotDuplicateAlreadyAnsweredQuestion() async throws {
        let latencyRecording = RecordingLatencyRecorder()
        let (client, transport) = makeClient(latencyRecording: latencyRecording)
        try await client.start(instructions: "test")
        let collector = AnswerEventCollector()
        await collector.start(consuming: client.events())

        transport.emit(.inputAudioBufferCommitted(itemID: "user-1", previousItemID: nil))
        transport.emit(.responseCreated(responseID: "resp-1"))
        transport.emit(.outputTextDelta(responseID: "resp-1", itemID: "out-1", delta: "Готовый ответ."))
        transport.emit(.outputTextDone(responseID: "resp-1", itemID: "out-1", text: "Готовый ответ."))
        transport.emit(.responseDone(responseID: "resp-1", status: "completed", outputItemIDs: ["out-1"]))
        try await Task.sleep(for: .milliseconds(20))

        let eventsBeforeDisconnect = await collector.events
        #expect(eventsBeforeDisconnect.contains(.completed(responseID: "resp-1")))

        let connectsBefore = transport.connectCallCount
        transport.emitClosed(reason: "network_lost")
        try await Task.sleep(for: .milliseconds(400))

        #expect(transport.connectCallCount > connectsBefore)
        #expect(transport.sentEvents.filter { if case .sessionUpdate = $0 { true } else { false } }.count >= 2)

        let eventsAfterReconnect = await collector.events
        let completedCount = eventsAfterReconnect.filter { $0 == .completed(responseID: "resp-1") }.count
        #expect(completedCount == 1)

        let recordedMetrics = await latencyRecording.metrics
        #expect(recordedMetrics.contains { if case .reconnectMs = $0 { true } else { false } })

        await client.stop()
    }

    @Test func rateLimitErrorSurfacesAsFailedWithoutLeakingMessageBody() async throws {
        let logCollector = LogCollector()
        let (client, transport) = makeClient(redactedLog: { line in Task { await logCollector.append(line) } })
        try await client.start(instructions: "test")

        let collector = AnswerEventCollector()
        await collector.start(consuming: client.events())

        transport.emit(.error(message: "rate limit exceeded for this account, retry after 30s", code: "rate_limit_exceeded"))
        try await Task.sleep(for: .milliseconds(20))

        let events = await collector.events
        #expect(events.contains(.failed("rate_limit_exceeded")))

        let lines = await logCollector.lines
        #expect(!lines.contains { $0.contains("retry after 30s") })

        await client.stop()
    }

    @Test func redactsSensitiveContentFromLogs() async throws {
        let logCollector = LogCollector()
        let secretKey = "sk-super-secret-value-should-never-appear"
        let (client, transport) = makeClient(
            credentialProviding: FakeCredentialProviding(apiKey: secretKey),
            redactedLog: { line in Task { await logCollector.append(line) } }
        )
        try await client.start(instructions: "test")

        let sensitiveErrorMessage = "leaked user transcript: \(secretKey) said something private"
        transport.emit(.error(message: sensitiveErrorMessage, code: "server_error"))
        try await Task.sleep(for: .milliseconds(20))

        let lines = await logCollector.lines
        #expect(!lines.contains { $0.contains(secretKey) })
        #expect(!lines.contains { $0.contains(sensitiveErrorMessage) })
        #expect(transport.lastBearerToken == secretKey)

        await client.stop()
    }

    @Test func unicodeAndMixedLanguageTextPreservedExactly() async throws {
        let (client, transport) = makeClient()
        try await client.start(instructions: "test")
        let collector = AnswerEventCollector()
        await collector.start(consuming: client.events())

        let expected = "Используй `kubectl rollout restart` — 🚀 это откатит поды без даунтайма."
        transport.emit(.inputAudioBufferCommitted(itemID: "user-1", previousItemID: nil))
        transport.emit(.responseCreated(responseID: "resp-1"))
        transport.emit(.outputTextDelta(responseID: "resp-1", itemID: "out-1", delta: expected))
        try await Task.sleep(for: .milliseconds(20))

        let events = await collector.events
        #expect(events.contains(.textDelta(responseID: "resp-1", text: expected)))

        await client.stop()
    }
}
