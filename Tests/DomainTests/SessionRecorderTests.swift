import Foundation
import Testing
@testable import Domain

actor FixedSessionContext: SessionContextProviding {
    var activeSessionID: SessionID?
    private(set) var captureRequests: [SessionSpanMode] = []

    init(_ id: SessionID?) {
        activeSessionID = id
    }

    func set(_ id: SessionID?) {
        activeSessionID = id
    }

    func sessionForCapture(mode: SessionSpanMode) async -> SessionID? {
        captureRequests.append(mode)
        return activeSessionID
    }
}

@Suite struct SessionRecorderTests {
    private struct Harness {
        let repository = InMemorySessionRepository()
        let clock = TestClock()
        let context: FixedSessionContext
        let recorder: SessionRecorder
        let sessionID: SessionID

        init() async throws {
            let session = try await repository.create(kind: .assistant, mode: .answers, at: clock.now)
            sessionID = session.id
            context = FixedSessionContext(session.id)
            let clock = clock
            recorder = SessionRecorder(repository: repository, sessions: context, now: { clock.now })
        }

        func utterances() async -> [SessionUtterance] {
            await repository.utterances[sessionID] ?? []
        }
    }

    @Test func finalTranscriptsAreWrittenWithSpeakerOriginAndWallClock() async throws {
        let harness = try await Harness()
        harness.clock.advance(5)
        await harness.recorder.record(TranscriptEvent(speaker: .them, itemID: "i1", text: "Расскажите про Kafka", language: "ru", isFinal: true))
        let themAt = harness.clock.now
        harness.clock.advance(3)
        await harness.recorder.record(TranscriptEvent(speaker: .me, itemID: "me_1", text: " Я бы начал с профилирования ", isFinal: true))
        await harness.recorder.flush()

        let stored = await harness.utterances()
        #expect(stored.map(\.speaker) == [.them, .me])
        #expect(stored.map(\.origin) == [.realtimeInput, .meChannel])
        #expect(stored.map(\.text) == ["Расскажите про Kafka", "Я бы начал с профилирования"])
        #expect(stored.first?.capturedAt == themAt)
        #expect(stored.last?.capturedAt == harness.clock.now)
        #expect(stored.first?.language == "ru")
        #expect(await harness.repository.sessions[harness.sessionID]?.lastActivityAt == harness.clock.now)
    }

    @Test func partialsAndEmptyFinalsAreIgnored() async throws {
        let harness = try await Harness()
        await harness.recorder.record(TranscriptEvent(speaker: .them, itemID: "i1", text: "Расска", isFinal: false))
        await harness.recorder.record(TranscriptEvent(speaker: .them, itemID: "i2", text: "   ", isFinal: true))
        await harness.recorder.flush()
        #expect(await harness.utterances().isEmpty)
    }

    @Test func duplicateFinalForSameItemIsWrittenOnce() async throws {
        let harness = try await Harness()
        let event = TranscriptEvent(speaker: .them, itemID: "i1", text: "Вопрос", isFinal: true)
        await harness.recorder.record(event)
        await harness.recorder.record(event)
        await harness.recorder.record(TranscriptEvent(speaker: .me, itemID: "i1", text: "Мой ответ", isFinal: true))
        await harness.recorder.flush()
        #expect(await harness.utterances().map(\.text) == ["Вопрос", "Мой ответ"])
    }

    @Test func eventsWithoutActiveSessionAreDropped() async throws {
        let harness = try await Harness()
        await harness.context.set(nil)
        await harness.recorder.record(TranscriptEvent(speaker: .them, itemID: "i1", text: "Вопрос", isFinal: true))
        await harness.recorder.flush()
        #expect(await harness.utterances().isEmpty)
        #expect(await harness.recorder.droppedWithoutSessionCount == 1)
    }

    @Test func failedWriteDoesNotBlockLaterWrites() async throws {
        let harness = try await Harness()
        await harness.repository.setFailAppend(true)
        await harness.recorder.record(TranscriptEvent(speaker: .them, itemID: "i1", text: "Потеряется", isFinal: true))
        await harness.recorder.flush()
        await harness.repository.setFailAppend(false)
        await harness.recorder.record(TranscriptEvent(speaker: .them, itemID: "i2", text: "Сохранится", isFinal: true))
        await harness.recorder.flush()
        #expect(await harness.utterances().map(\.text) == ["Сохранится"])
        #expect(await harness.recorder.failedWriteCount == 1)
        #expect(await harness.recorder.writtenCount == 1)
    }

    @Test func attachedStreamIsRecordedUntilDetached() async throws {
        let harness = try await Harness()
        let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream()
        await harness.recorder.attach(stream)
        continuation.yield(TranscriptEvent(speaker: .them, itemID: "i1", text: "Первый", isFinal: true))
        await waitUntil { await harness.recorder.writtenCount == 1 }
        await harness.recorder.detach()
        continuation.yield(TranscriptEvent(speaker: .them, itemID: "i2", text: "Второй", isFinal: true))
        try await Task.sleep(for: .milliseconds(30))
        await harness.recorder.flush()
        #expect(await harness.utterances().map(\.text) == ["Первый"])
    }
}

@Suite struct SessionFinalizationTests {
    private func makeCoordinator(_ repository: InMemorySessionRepository, _ modes: FakeSessionModes, beforeFinalize: @escaping @Sendable () async -> Void = {}) -> SessionCoordinator {
        SessionCoordinator(repository: repository, modes: modes, idleCheckInterval: .seconds(3_600), beforeFinalize: beforeFinalize)
    }

    @Test func emptySessionIsDiscardedOnStop() async throws {
        let repository = InMemorySessionRepository()
        let modes = FakeSessionModes()
        let coordinator = makeCoordinator(repository, modes)
        await coordinator.startObserving()
        let events = coordinator.events(subscriber: "test")
        let id = try await coordinator.start()
        await coordinator.stop()
        #expect(await repository.sessions[id] == nil)
        #expect(await repository.discardedSessions == [id])
        var received: [SessionEvent] = []
        for await event in events {
            received.append(event)
            if case .discarded = event { break }
        }
        #expect(received.suffix(2) == [.stopped(id, reason: .user), .discarded(id)])
    }

    @Test func pendingWritesAreFlushedBeforeEmptinessCheck() async throws {
        let repository = InMemorySessionRepository()
        let modes = FakeSessionModes()
        let gate = FixedSessionContext(nil)
        let recorder = SessionRecorder(repository: repository, sessions: gate)
        let coordinator = makeCoordinator(repository, modes, beforeFinalize: { await recorder.flush() })
        await coordinator.startObserving()
        let id = try await coordinator.start()
        await gate.set(id)
        await recorder.record(TranscriptEvent(speaker: .them, itemID: "i1", text: "Вопрос", isFinal: true))
        await coordinator.stop()
        #expect(await repository.sessions[id]?.status == .completed)
        #expect(await repository.discardedSessions.isEmpty)
    }

    @Test func starredOrRecordedSessionsAreKept() async throws {
        let repository = InMemorySessionRepository()
        let modes = FakeSessionModes()
        let coordinator = makeCoordinator(repository, modes)
        await coordinator.startObserving()
        let id = try await coordinator.start()
        try await repository.addBookmark(SessionBookmark(sessionID: id, kind: .moment, markedAt: Date()))
        await coordinator.stop()
        #expect(await repository.sessions[id] != nil)

        let recording = await coordinator.sessionForCapture(mode: .recording)
        let recordingID = try #require(recording)
        await coordinator.stop()
        #expect(await repository.sessions[recordingID] != nil)
    }

    @Test func captureClaimReusesActiveSession() async throws {
        let repository = InMemorySessionRepository()
        let modes = FakeSessionModes()
        let coordinator = makeCoordinator(repository, modes)
        await coordinator.startObserving()
        let id = try await coordinator.start()
        #expect(await coordinator.sessionForCapture(mode: .recording) == id)
        #expect(await repository.sessions.count == 1)
    }

    @Test func concurrentCaptureClaimsCreateOneSessionAndModeSyncAddsNoSecond() async throws {
        let repository = InMemorySessionRepository()
        let modes = FakeSessionModes()
        let coordinator = makeCoordinator(repository, modes)
        await coordinator.startObserving()
        _ = await modes.requestTransition(to: .recording)
        async let first = coordinator.sessionForCapture(mode: .recording)
        async let second = coordinator.sessionForCapture(mode: .recording)
        let claimed = await [first, second]
        await waitUntil {
            if case .active(_, _, .recording) = await coordinator.currentState { return true }
            return false
        }
        #expect(claimed[0] != nil)
        #expect(claimed[0] == claimed[1])
        #expect(await coordinator.activeSessionID == claimed[0])
        #expect(await repository.sessions.count == 1)
        let claimedID = try #require(claimed[0])
        let session = try #require(await repository.sessions[claimedID])
        #expect(session.spans.map(\.mode) == [.recording])
    }
}

@Suite struct SessionAttachedWritersTests {
    @Test func recordingJoinsActiveSessionWithoutCreatingOrFinishingMeeting() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let microphone = FakeMicrophoneCapturing()
        let transcribing = FakeLocalTranscribing()
        let repository = FakeMeetingRepository()
        let sessionID = SessionID()
        let context = FixedSessionContext(sessionID)
        let startedAt = Date(timeIntervalSince1970: 1_793_000_000)
        await transcribing.setResult([TranscribedSegment(text: "привет", startMs: 2_500, endMs: 3_000, source: .local)])
        let controller = RecordingModeController(
            captureHub: CaptureHub(system: systemAudio, microphone: microphone),
            transcribing: transcribing,
            repository: repository,
            sessions: context,
            now: { startedAt },
            chunkDurationSeconds: 3600
        )
        try await controller.start()
        await microphone.emit(PCMAudioFrame(samples: [0], sampleRate: 24000, channelCount: 1, capturedAt: Date(), source: .microphone))
        await waitUntil { await controller.ingestedFrameCountForTesting == 1 }
        await controller.stop()

        #expect(await context.captureRequests == [.recording])
        #expect(await repository.createdMeetings.isEmpty)
        #expect(await repository.finishedMeetings.isEmpty)
        #expect(await repository.appendedSegments.map(\.0) == [sessionID])
        #expect(await repository.appendedCapturedAt == [startedAt.addingTimeInterval(2.5)])
    }

    @Test func recordingWithoutSessionCreatesItsOwnMeeting() async throws {
        let repository = FakeMeetingRepository()
        let transcribing = FakeLocalTranscribing()
        let microphone = FakeMicrophoneCapturing()
        await transcribing.setResult([TranscribedSegment(text: "привет", startMs: 0, endMs: 500, source: .local)])
        let controller = RecordingModeController(
            captureHub: CaptureHub(system: FakeSystemAudioCapturing(), microphone: microphone),
            transcribing: transcribing,
            repository: repository,
            sessions: FixedSessionContext(nil),
            chunkDurationSeconds: 3600
        )
        try await controller.start()
        await microphone.emit(PCMAudioFrame(samples: [0], sampleRate: 24000, channelCount: 1, capturedAt: Date(), source: .microphone))
        await waitUntil { await controller.ingestedFrameCountForTesting == 1 }
        await controller.stop()
        let created = await repository.createdMeetings
        #expect(created.count == 1)
        #expect(await repository.finishedMeetings == created)
        #expect(await repository.appendedCapturedAt == [nil])
    }

    @Test func answerDraftsCarryTheSessionActiveWhenTheyBegan() async throws {
        let repository = FakeQuestionAnswerRepository()
        let sessionID = SessionID()
        let context = FixedSessionContext(sessionID)
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model", sessions: context)
        await logger.beginDraft(responseID: "r1", triggerKind: .manual, sourceAppBundleID: nil, contextWindowStartedAt: Date(), questionItemIDs: ["u1"])
        await context.set(nil)
        await logger.recordTranscript(TranscriptEvent(speaker: .them, itemID: "u1", text: "Вопрос", isFinal: true))
        await logger.recordCompleted(responseID: "r1", finalText: "Ответ", responseTotalMs: 100)
        await logger.flush()
        let saved = await repository.savedPairs
        #expect(!saved.isEmpty)
        #expect(saved.allSatisfy { $0.sessionID == sessionID })
    }

    @Test func answerDraftsWithoutSessionStayUnbound() async throws {
        let repository = FakeQuestionAnswerRepository()
        let logger = QuestionAnswerLogger(repository: repository, answerModelID: "test-model", sessions: FixedSessionContext(nil))
        await logger.beginDraft(responseID: "r1", triggerKind: .manual, sourceAppBundleID: nil, contextWindowStartedAt: Date(), questionItemIDs: [])
        await logger.recordCompleted(responseID: "r1", finalText: "Ответ", responseTotalMs: 100)
        await logger.flush()
        #expect(await repository.savedPairs.allSatisfy { $0.sessionID == nil })
    }
}
