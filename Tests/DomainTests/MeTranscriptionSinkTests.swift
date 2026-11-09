import Foundation
import Testing
@testable import Domain

actor FakeMeTranscriber: MeTranscribing {
    private let status = AsyncBroadcaster<MeTranscriptionStatus>(replayLatest: true, initial: .stopped)
    private var continuation: AsyncStream<TranscriptDelta>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var appendedFrames: [PCMAudioFrame] = []
    private(set) var commitCount = 0
    private(set) var requestedLanguages: [String] = []
    var startError: TestError?

    var isActive: Bool { continuation != nil }

    func setStartError(_ error: TestError?) { startError = error }

    func start(languages: [String]) async throws -> AsyncStream<TranscriptDelta> {
        startCount += 1
        requestedLanguages = languages
        status.yield(.connecting)
        if let startError {
            status.yield(.unavailable(reason: "connect_failed"))
            throw startError
        }
        let (stream, continuation) = AsyncStream<TranscriptDelta>.makeStream()
        self.continuation = continuation
        status.yield(.live)
        return stream
    }

    func appendAudio(_ frame: PCMAudioFrame) async {
        guard continuation != nil else { return }
        appendedFrames.append(frame)
    }

    func commitTurn() async {
        guard continuation != nil else { return }
        commitCount += 1
    }

    nonisolated func statusUpdates() -> AsyncStream<MeTranscriptionStatus> {
        status.subscribe("fake-me-status")
    }

    func stop() async {
        stopCount += 1
        continuation?.finish()
        continuation = nil
        status.yield(.stopped)
    }

    func emitFinal(itemID: String, text: String, language: String? = nil) {
        continuation?.yield(TranscriptDelta(itemID: itemID, text: text, isFinal: true, source: .remote, language: language))
    }

    func emitPartial(itemID: String, text: String) {
        continuation?.yield(TranscriptDelta(itemID: itemID, text: text, isFinal: false, source: .remote))
    }

    func emitStatus(_ value: MeTranscriptionStatus) {
        status.yield(value)
    }
}

actor ItemCollector<Element: Sendable> {
    private(set) var items: [Element] = []
    func append(_ item: Element) { items.append(item) }
}

func collectItems<Element: Sendable>(_ stream: AsyncStream<Element>) -> ItemCollector<Element> {
    let collector = ItemCollector<Element>()
    Task {
        for await item in stream { await collector.append(item) }
    }
    return collector
}

private struct SinkHarness {
    let microphone = FakeMicrophoneCapturing()
    let system = FakeSystemAudioCapturing()
    let transcriber = FakeMeTranscriber()
    let responder = FakeLiveResponder()
    let hub: CaptureHub
    let sink: MeTranscriptionSink

    init(dedupGrace: Duration = .zero) {
        hub = CaptureHub(system: system, microphone: microphone)
        sink = MeTranscriptionSink(
            captureHub: hub,
            transcriber: transcriber,
            responder: responder,
            dedupGrace: dedupGrace
        )
    }

    func feed(_ frames: [PCMAudioFrame]) async {
        for frame in frames { await microphone.emit(frame) }
        await waitUntil { await sink.processedFrameCount >= frames.count }
    }
}

@Suite struct MeTranscriptionSinkTests {
    private let speech = MeSpeechFixture(segments: [.gap(ms: 400)] + MeSpeechFixture.russianQuestionAnswer + [.gap(ms: 900)])

    @Test func speechTurnIsStreamedWithPreRollAndCommittedOnce() async throws {
        let harness = SinkHarness()
        #expect(await harness.sink.start())
        #expect(await harness.hub.activeSources == [.microphone])
        #expect(await harness.hub.microphoneOptions?.sampleRate == 24_000)
        #expect(await harness.transcriber.requestedLanguages == ["ru", "en"])
        let frames = speech.frames()
        await harness.feed(frames)
        #expect(await harness.transcriber.commitCount == 1)
        let appended = await harness.transcriber.appendedFrames
        #expect(!appended.isEmpty)
        #expect(appended.count < frames.count)
        let firstSpeechAt = frames[20].capturedAt
        #expect(try #require(appended.first).capturedAt < firstSpeechAt)
        await harness.sink.stop()
    }

    @Test func silenceAndNoiseSendNothingToOpenAI() async {
        let harness = SinkHarness()
        await harness.sink.start()
        await harness.feed(MeSpeechFixture(segments: [.gap(ms: 3_000)], noiseAmplitude: 100).frames())
        #expect(await harness.transcriber.appendedFrames.isEmpty)
        #expect(await harness.transcriber.commitCount == 0)
        await harness.sink.stop()
    }

    @Test func loudSystemAudioKeepsMeTurnClosed() async {
        let harness = SinkHarness()
        await harness.sink.start()
        let frames = speech.frames()
        for frame in frames where frame.samples.count > 0 {
            harness.hub.levels.yield(AudioLevel(kind: .systemAudio, rmsDBFS: -18, peakDBFS: -6, at: frame.capturedAt))
        }
        try? await Task.sleep(for: .milliseconds(50))
        await harness.feed(frames)
        #expect(await harness.transcriber.appendedFrames.isEmpty)
        #expect(await harness.transcriber.commitCount == 0)
        await harness.sink.stop()
    }

    @Test func finalTranscriptIsInjectedAsMeAndPublished() async throws {
        let harness = SinkHarness()
        let transcripts = collectItems(harness.sink.transcripts(subscriber: "test"))
        await harness.sink.start()
        await harness.transcriber.emitPartial(itemID: "me_1", text: "Я пять")
        await harness.transcriber.emitFinal(itemID: "me_1", text: "  Я пять лет писал на Kafka ", language: "ru")
        await waitUntil { await harness.sink.injectedCount == 1 }
        #expect(await harness.responder.injectedContexts == [.me("Я пять лет писал на Kafka")])
        await waitUntil { await transcripts.items.count == 1 }
        let event = try #require(await transcripts.items.first)
        #expect(event == TranscriptEvent(speaker: .me, itemID: "me_1", text: "Я пять лет писал на Kafka", language: "ru", isFinal: true))
        await harness.sink.stop()
    }

    @Test func echoOfRemoteSpeakerIsDropped() async {
        let harness = SinkHarness()
        await harness.sink.start()
        await harness.sink.noteRemoteTranscript(TranscriptEvent(speaker: .them, itemID: "them_1", text: "What is your experience with Swift concurrency?", isFinal: true))
        await harness.transcriber.emitFinal(itemID: "me_1", text: "your experience with Swift concurrency")
        await harness.transcriber.emitFinal(itemID: "me_2", text: "I shipped async/await code for two years")
        await waitUntil { await harness.sink.injectedCount == 1 }
        await waitUntil { await harness.sink.droppedEchoCount == 1 }
        #expect(await harness.responder.injectedContexts == [.me("I shipped async/await code for two years")])
        await harness.sink.stop()
    }

    @Test func remoteTranscriptArrivingWithinGraceStillDropsEcho() async {
        let harness = SinkHarness(dedupGrace: .milliseconds(150))
        await harness.sink.start()
        await harness.transcriber.emitFinal(itemID: "me_1", text: "Расскажите про ваш последний проект")
        try? await Task.sleep(for: .milliseconds(20))
        await harness.sink.noteRemoteTranscript(TranscriptEvent(speaker: .them, itemID: "them_1", text: "Расскажите про ваш последний проект.", isFinal: false))
        await waitUntil { await harness.sink.droppedEchoCount == 1 }
        #expect(await harness.sink.droppedEchoCount == 1)
        #expect(await harness.responder.injectedContexts.isEmpty)
        await harness.sink.stop()
    }

    @Test func ownTranscriptsAreNotUsedAsRemoteHistory() async {
        let harness = SinkHarness()
        await harness.sink.start()
        await harness.sink.noteRemoteTranscript(TranscriptEvent(speaker: .me, itemID: "me_0", text: "I use Swift every day", isFinal: true))
        await harness.transcriber.emitFinal(itemID: "me_1", text: "I use Swift every day")
        await waitUntil { await harness.sink.injectedCount == 1 }
        #expect(await harness.sink.droppedEchoCount == 0)
        await harness.sink.stop()
    }

    @Test func transcriberConnectFailureGivesOneNoticeAndNoMicrophone() async {
        let harness = SinkHarness()
        let notices = collectItems(harness.hub.notices.subscribe("test"))
        await harness.transcriber.setStartError(TestError(message: "offline"))
        #expect(await harness.sink.start() == false)
        await waitUntil { await notices.items.count >= 1 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await notices.items == [.meTranscriptionUnavailable(reason: "connect_failed")])
        #expect(await harness.hub.activeSources.isEmpty)
        #expect(await harness.microphone.startCalled == false)
        #expect(await harness.sink.isRunning == false)
    }

    @Test func microphoneFailureGivesNoticeAndStopsTranscriber() async {
        let harness = SinkHarness()
        let notices = collectItems(harness.hub.notices.subscribe("test"))
        await harness.microphone.setStartError(TestError(message: "denied"))
        #expect(await harness.sink.start() == false)
        await waitUntil { await notices.items.count >= 1 }
        #expect(await notices.items == [.meTranscriptionUnavailable(reason: "microphone_unavailable")])
        #expect(await harness.transcriber.isActive == false)
        #expect(await harness.transcriber.stopCount == 1)
    }

    @Test func reconnectExhaustionBecomesNotice() async {
        let harness = SinkHarness()
        let notices = collectItems(harness.hub.notices.subscribe("test"))
        await harness.sink.start()
        await harness.transcriber.emitStatus(.reconnecting(attempt: 1))
        await harness.transcriber.emitStatus(.unavailable(reason: "reconnect_exhausted"))
        await waitUntil { await notices.items.count >= 1 }
        #expect(await notices.items == [.meTranscriptionUnavailable(reason: "reconnect_exhausted")])
        await harness.sink.stop()
    }

    @Test func stopReleasesMicrophoneStopsTranscriberAndIgnoresLateFinals() async {
        let harness = SinkHarness(dedupGrace: .milliseconds(80))
        await harness.sink.start()
        await harness.transcriber.emitFinal(itemID: "me_1", text: "late remark")
        try? await Task.sleep(for: .milliseconds(10))
        await harness.sink.stop()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await harness.hub.activeSources.isEmpty)
        #expect(await harness.microphone.stopCalled)
        #expect(await harness.transcriber.stopCount == 1)
        #expect(await harness.responder.injectedContexts.isEmpty)
        #expect(await harness.sink.isRunning == false)
    }
}
