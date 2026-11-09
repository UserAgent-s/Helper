import Domain
import Foundation
import Persistence
import Testing
@testable import RealtimeClient

private actor SilentSystemAudio: SystemAudioCapturing {
    func start(scope: SystemAudioScope) async throws -> SystemAudioCaptureStart {
        SystemAudioCaptureStart(frames: AsyncStream { _ in }, effectiveScope: scope)
    }
    func stop() async {}
}

private actor PushMicrophone: MicrophoneCapturing {
    private var continuation: AsyncStream<PCMAudioFrame>.Continuation?

    func start(options: MicrophoneCaptureOptions) async throws -> AsyncStream<PCMAudioFrame> {
        let (stream, continuation) = AsyncStream<PCMAudioFrame>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }

    func emit(_ frame: PCMAudioFrame) {
        continuation?.yield(frame)
    }
}

private actor ActiveSession: SessionContextProviding {
    let id: SessionID
    init(_ id: SessionID) { self.id = id }
    var activeSessionID: SessionID? { id }
    func sessionForCapture(mode: SessionSpanMode) async -> SessionID? { id }
}

private func spokenTurn(start: Date) -> [PCMAudioFrame] {
    let rate = 24_000
    var frames: [PCMAudioFrame] = []
    var offsetMs = 0
    var index = 0
    for (durationMs, amplitude) in [(400, 0.0), (900, 6_000.0), (900, 0.0)] {
        for _ in 0..<(durationMs / 20) {
            var samples: [Int16] = []
            for _ in 0..<(rate / 50) {
                samples.append(Int16(sin(Double(index) / Double(rate) * 2 * .pi * 220) * amplitude))
                index += 1
            }
            frames.append(PCMAudioFrame(samples: samples, sampleRate: rate, channelCount: 1, capturedAt: start.addingTimeInterval(Double(offsetMs) / 1000), source: .microphone))
            offsetMs += 20
        }
    }
    return frames
}

@Suite struct SessionPersistenceIntegrationTests {
    private struct Stack {
        let database = SQLiteDatabase(path: ":memory:")
        let sessions: SQLiteSessionRepository
        let answers: SQLiteQuestionAnswerRepository
        let answerTransport = FakeRealtimeWebSocketTransport()
        let meTransport = FakeRealtimeWebSocketTransport()
        let microphone = PushMicrophone()
        let hub: CaptureHub
        let logger: QuestionAnswerLogger
        let recorder: SessionRecorder
        let meChannel: MeTranscriptionSink
        let controller: AnswersModeController
        let sessionID: SessionID

        init() async throws {
            sessions = SQLiteSessionRepository(database: database)
            answers = SQLiteQuestionAnswerRepository(database: database)
            sessionID = try await sessions.create(kind: .assistant, mode: .answers, at: Date()).id
            let context = ActiveSession(sessionID)
            hub = CaptureHub(system: SilentSystemAudio(), microphone: microphone)
            let client = OpenAIRealtimeAnswerClient(
                transport: answerTransport,
                credentialProviding: FakeCredentialProviding(),
                latencyRecording: RecordingLatencyRecorder(),
                reconnectBaseDelay: .milliseconds(10),
                maxReconnectAttempts: 1
            )
            let me = OpenAIRealtimeTranscriptionClient(transport: meTransport, credentialProviding: FakeCredentialProviding())
            meChannel = MeTranscriptionSink(captureHub: hub, transcriber: me, responder: client, dedupGrace: .zero)
            logger = QuestionAnswerLogger(repository: answers, answerModelID: "gpt-realtime-test", sessions: context)
            recorder = SessionRecorder(repository: sessions, sessions: context)
            controller = AnswersModeController(
                captureHub: hub,
                realtime: client,
                answerTrigger: ManualAnswerTrigger(),
                instructionsProvider: { "test" },
                questionAnswerLogger: logger,
                meChannel: meChannel
            )
            await recorder.attach(controller.transcriptEvents(subscriber: "session-recorder"))
        }
    }

    @Test func answeredQuestionPersistedWithSessionID() async throws {
        let stack = try await Stack()
        try await stack.controller.start()

        stack.answerTransport.emit(.speechStarted(itemID: "u1", audioStartMs: 0))
        stack.answerTransport.emit(.speechStopped(itemID: "u1", audioEndMs: 1_200))
        stack.answerTransport.emit(.inputAudioBufferCommitted(itemID: "u1", previousItemID: nil))
        stack.answerTransport.emit(.inputAudioTranscriptionCompleted(itemID: "u1", transcript: "Чем Kafka отличается от RabbitMQ?", language: "ru"))
        stack.answerTransport.emit(.responseCreated(responseID: "r1"))
        stack.answerTransport.emit(.outputTextDelta(responseID: "r1", itemID: "o1", delta: "Kafka хранит лог"))
        stack.answerTransport.emit(.outputTextDone(responseID: "r1", itemID: "o1", text: "Kafka хранит лог"))
        stack.answerTransport.emit(.responseDone(responseID: "r1", status: "completed", outputItemIDs: ["o1"]))

        await waitUntil {
            await stack.logger.flush()
            return (try? await stack.sessions.latestCompletedAnswerID(sessionID: stack.sessionID)) != nil
        }
        await stack.controller.stop()
        await stack.logger.flush()
        await stack.recorder.flush()

        let detail = try #require(try await stack.sessions.detail(sessionID: stack.sessionID))
        #expect(detail.questionAnswers.count == 1)
        let answer = try #require(detail.questionAnswers.first)
        #expect(answer.sessionID == stack.sessionID)
        #expect(answer.status == .completed)
        #expect(answer.answerText == "Kafka хранит лог")
        #expect(answer.questionText == "Чем Kafka отличается от RabbitMQ?")
        #expect(try await stack.answers.history(limit: 10).allSatisfy { $0.sessionID == stack.sessionID })
        #expect(detail.utterances.map(\.text) == ["Чем Kafka отличается от RabbitMQ?"])
    }

    @Test func transcriptSegmentsPersistedWithSpeaker() async throws {
        let stack = try await Stack()
        let before = Date().addingTimeInterval(-1)
        try await stack.controller.start()

        stack.answerTransport.emit(.inputAudioTranscriptionDelta(itemID: "t1", delta: "Расскажите"))
        stack.answerTransport.emit(.inputAudioTranscriptionCompleted(itemID: "t1", transcript: "Расскажите про шардирование", language: "ru"))
        await waitUntil { await stack.recorder.writtenCount == 1 }

        let frames = spokenTurn(start: Date())
        for frame in frames { await stack.microphone.emit(frame) }
        await waitUntil { await stack.meChannel.processedFrameCount >= frames.count }
        stack.meTransport.emit(.inputAudioTranscriptionCompleted(itemID: "me_1", transcript: "Я бы шардировал по клиенту", language: "ru"))
        await waitUntil { await stack.recorder.writtenCount == 2 }

        await stack.controller.stop()
        await stack.recorder.flush()
        let after = Date().addingTimeInterval(1)

        let detail = try #require(try await stack.sessions.detail(sessionID: stack.sessionID))
        #expect(detail.utterances.map(\.speaker) == [.them, .me])
        #expect(detail.utterances.map(\.origin) == [.realtimeInput, .meChannel])
        #expect(detail.utterances.map(\.text) == ["Расскажите про шардирование", "Я бы шардировал по клиенту"])
        for utterance in detail.utterances {
            let capturedAt = try #require(utterance.capturedAt)
            #expect(capturedAt >= before.addingTimeInterval(-1) && capturedAt <= after)
        }
        #expect(await stack.recorder.droppedWithoutSessionCount == 0)
    }
}
