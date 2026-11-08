import Foundation
@testable import Domain

struct TestError: Error, Sendable, Equatable {
    let message: String
}

actor CallRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

final class FakeModeController: ModeController, Sendable {
    let label: String
    let recorder: CallRecorder
    let startError: TestError?
    let startDelay: Duration
    let stopDelay: Duration
    private let failureStream: AsyncStream<String>
    private let failureContinuation: AsyncStream<String>.Continuation

    init(label: String, recorder: CallRecorder, startError: TestError? = nil, startDelay: Duration = .zero, stopDelay: Duration = .zero) {
        self.label = label
        self.recorder = recorder
        self.startError = startError
        self.startDelay = startDelay
        self.stopDelay = stopDelay
        (failureStream, failureContinuation) = AsyncStream<String>.makeStream()
    }

    func start() async throws {
        await recorder.record("\(label).start.begin")
        if startDelay > .zero { try? await Task.sleep(for: startDelay) }
        if let startError {
            await recorder.record("\(label).start.threw")
            throw startError
        }
        await recorder.record("\(label).start.end")
    }

    func stop() async {
        await recorder.record("\(label).stop.begin")
        if stopDelay > .zero { try? await Task.sleep(for: stopDelay) }
        await recorder.record("\(label).stop.end")
    }

    nonisolated func failures() -> AsyncStream<String> {
        failureStream
    }

    func emitFailure(_ reason: String) {
        failureContinuation.yield(reason)
    }
}

actor StreamEventCollector {
    private(set) var events: [AnswerStreamEvent] = []

    func start(consuming stream: AsyncStream<AnswerStreamEvent>) {
        Task { [weak self] in
            for await event in stream {
                await self?.append(event)
            }
        }
    }

    private func append(_ event: AnswerStreamEvent) {
        events.append(event)
    }
}

actor FailureCollector {
    private(set) var reasons: [String] = []

    func start(consuming stream: AsyncStream<String>) {
        Task { [weak self] in
            for await reason in stream {
                await self?.append(reason)
            }
        }
    }

    private func append(_ reason: String) {
        reasons.append(reason)
    }
}

actor FakeSystemAudioCapturing: SystemAudioCapturing {
    private let stream: AsyncStream<PCMAudioFrame>
    private let continuation: AsyncStream<PCMAudioFrame>.Continuation
    private(set) var startCalled = false
    private(set) var stopCalled = false
    var startError: TestError?

    init() {
        (stream, continuation) = AsyncStream<PCMAudioFrame>.makeStream()
    }

    func start(targetApplicationBundleID: String?) async throws -> AsyncStream<PCMAudioFrame> {
        startCalled = true
        if let startError { throw startError }
        return stream
    }

    func stop() async {
        stopCalled = true
        continuation.finish()
    }

    func emit(_ frame: PCMAudioFrame) {
        continuation.yield(frame)
    }

    func simulateUnexpectedEnd() {
        continuation.finish()
    }
}

actor FakeMicrophoneCapturing: MicrophoneCapturing {
    private let stream: AsyncStream<PCMAudioFrame>
    private let continuation: AsyncStream<PCMAudioFrame>.Continuation
    private(set) var startCalled = false
    private(set) var stopCalled = false
    var startError: TestError?

    init() {
        (stream, continuation) = AsyncStream<PCMAudioFrame>.makeStream()
    }

    func start() async throws -> AsyncStream<PCMAudioFrame> {
        startCalled = true
        if let startError { throw startError }
        return stream
    }

    func stop() async {
        stopCalled = true
        continuation.finish()
    }

    func emit(_ frame: PCMAudioFrame) {
        continuation.yield(frame)
    }
}

actor FakeRealtimeAnswering: RealtimeAnswering {
    private let stream: AsyncStream<RealtimeAnswerEvent>
    private let continuation: AsyncStream<RealtimeAnswerEvent>.Continuation
    private(set) var startCalled = false
    private(set) var stopCalled = false
    private(set) var forceResponseCallCount = 0
    private(set) var appendedFrameCount = 0
    var forceResponseError: TestError?

    init() {
        (stream, continuation) = AsyncStream<RealtimeAnswerEvent>.makeStream()
    }

    func setForceResponseError(_ error: TestError?) {
        forceResponseError = error
    }

    func start(instructions: String) async throws {
        startCalled = true
    }

    func appendAudio(_ frame: PCMAudioFrame) async {
        appendedFrameCount += 1
    }

    nonisolated func events() -> AsyncStream<RealtimeAnswerEvent> {
        stream
    }

    func forceResponse() async throws {
        forceResponseCallCount += 1
        if let forceResponseError { throw forceResponseError }
    }

    func stop() async {
        stopCalled = true
        continuation.finish()
    }

    func emit(_ event: RealtimeAnswerEvent) {
        continuation.yield(event)
    }
}

actor FakeAnswerTriggering: AnswerTriggering {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    nonisolated func events() -> AsyncStream<Void> {
        stream
    }

    func fire() {
        continuation.yield(())
    }
}

actor FakeLocalTranscribing: LocalTranscribing {
    private(set) var transcribeCallCount = 0
    private(set) var receivedFrameBatches: [[PCMAudioFrame]] = []
    var result: [TranscribedSegment] = []
    var error: TestError?
    var delay: Duration?

    func setResult(_ segments: [TranscribedSegment]) {
        result = segments
    }

    func setError(_ error: TestError?) {
        self.error = error
    }

    func setDelay(_ delay: Duration?) {
        self.delay = delay
    }

    func transcribe(_ frames: [PCMAudioFrame]) async throws -> [TranscribedSegment] {
        transcribeCallCount += 1
        receivedFrameBatches.append(frames)
        if let delay {
            try await Task.sleep(for: delay)
        }
        if let error { throw error }
        return result
    }
}

actor SourceAwareFakeLocalTranscribing: LocalTranscribing {
    private(set) var transcribeCallCount = 0

    func transcribe(_ frames: [PCMAudioFrame]) async throws -> [TranscribedSegment] {
        transcribeCallCount += 1
        guard let firstSource = frames.first?.source else { return [] }
        let source: TranscriptSource = firstSource == .microphone ? .local : .remote
        let text = firstSource == .microphone ? "mic phrase" : "system phrase"
        return [TranscribedSegment(text: text, startMs: 0, endMs: 100, source: source)]
    }
}

actor ScriptedLocalTranscribing: LocalTranscribing {
    private var resultsByFirstSample: [Int16: [TranscribedSegment]] = [:]

    func setResult(_ segments: [TranscribedSegment], forFirstSample marker: Int16) {
        resultsByFirstSample[marker] = segments
    }

    func transcribe(_ frames: [PCMAudioFrame]) async throws -> [TranscribedSegment] {
        guard let marker = frames.first?.samples.first, let segments = resultsByFirstSample[marker] else {
            return []
        }
        return segments
    }
}

actor FakeQuestionAnswerRepository: QuestionAnswerRepository {
    private(set) var savedPairs: [QuestionAnswerPair] = []
    private(set) var deletedIDs: [UUID] = []
    private(set) var deleteAllCallCount = 0

    func save(_ pair: QuestionAnswerPair) async throws {
        savedPairs.append(pair)
    }

    func delete(id: UUID) async throws {
        deletedIDs.append(id)
    }

    func deleteAll() async throws {
        deleteAllCallCount += 1
    }

    func history(limit: Int) async throws -> [QuestionAnswerPair] {
        Array(savedPairs.suffix(limit))
    }

    func search(query: String) async throws -> [QuestionAnswerPair] {
        savedPairs.filter { ($0.questionText?.contains(query) ?? false) || $0.answerText.contains(query) }
    }

    func latest(id: UUID) -> QuestionAnswerPair? {
        savedPairs.last { $0.id == id }
    }

    func latest(responseID: String) -> QuestionAnswerPair? {
        savedPairs.last { $0.responseID == responseID }
    }
}

actor FakeLatencyRecording: LatencyRecording {
    private(set) var recordedMetrics: [LatencyMetric] = []

    func record(_ metric: LatencyMetric) async {
        recordedMetrics.append(metric)
    }
}

actor FakeMeetingAudioRecording: MeetingAudioRecording {
    private(set) var startedMeetings: [MeetingID] = []
    private(set) var writtenFrames: [PCMAudioFrame] = []
    private(set) var finishCallCount = 0

    func start(meetingID: MeetingID) async {
        startedMeetings.append(meetingID)
    }

    func write(_ frame: PCMAudioFrame) async {
        writtenFrames.append(frame)
    }

    func finish() async {
        finishCallCount += 1
    }
}

actor FakeMeetingRepository: MeetingRepository {
    private(set) var createdMeetings: [MeetingID] = []
    private(set) var appendedSegments: [(MeetingID, TranscribedSegment)] = []
    private(set) var finishedMeetings: [MeetingID] = []
    private(set) var deletedMeetings: [MeetingID] = []
    private(set) var deleteAllCallCount = 0
    var createError: TestError?

    func createMeeting(startedAt: Date, sourceAppBundleID: String?) async throws -> MeetingID {
        if let createError { throw createError }
        let id = MeetingID()
        createdMeetings.append(id)
        return id
    }

    func appendSegment(_ segment: TranscribedSegment, meetingID: MeetingID) async throws {
        appendedSegments.append((meetingID, segment))
    }

    func finish(meetingID: MeetingID, endedAt: Date) async throws {
        finishedMeetings.append(meetingID)
    }

    func reconcileInterruptedMeetings() async throws -> [MeetingID] {
        []
    }

    func fetch(meetingID: MeetingID) async throws -> Meeting {
        Meeting(id: meetingID, startedAt: Date(), endedAt: Date(), status: .completed, segments: [])
    }

    func history(limit: Int, offset: Int) async throws -> [Meeting] {
        []
    }

    func search(query: String) async throws -> [Meeting] {
        []
    }

    func delete(meetingID: MeetingID) async throws {
        deletedMeetings.append(meetingID)
    }

    func deleteAll() async throws {
        deleteAllCallCount += 1
    }
}
