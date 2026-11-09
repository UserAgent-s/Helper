import CompanionProtocol
import Domain
import Foundation
@testable import CompanionBridge
@testable import RealtimeClient

struct TimedOut: Error {}

func withTimeout<T: Sendable>(_ seconds: Double = 5, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { continuation in
        gate.install(continuation)
        let work = Task {
            do {
                gate.resume(.success(try await body()))
            } catch {
                gate.resume(.failure(error))
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            gate.resume(.failure(TimedOut()))
            work.cancel()
        }
    }
}

final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ result: Result<T, any Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<T, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

func waitUntil(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

actor EventSink {
    private(set) var events: [ServerEvent] = []

    func append(_ event: ServerEvent) {
        events.append(event)
    }

    var texts: [String] {
        events.compactMap { event in
            switch event {
            case .answerDelta(let delta): delta.text
            case .answerReplace(let replace): replace.text
            default: nil
            }
        }
    }

    var types: [String] {
        events.map(\.type)
    }
}

actor FakeDomainControl: CompanionDomainControlling {
    var mode: AppMode = .answers
    var inFlight = false
    var transitionResult: ModeTransitionResult?
    private(set) var resetCount = 0
    private(set) var answerNowCount = 0
    private(set) var requestedModes: [AppMode] = []

    func set(mode: AppMode? = nil, inFlight: Bool? = nil, transitionResult: ModeTransitionResult? = nil) {
        if let mode { self.mode = mode }
        if let inFlight { self.inFlight = inFlight }
        if let transitionResult { self.transitionResult = transitionResult }
    }

    func currentMode() async -> AppMode { mode }

    func requestMode(_ mode: AppMode) async -> ModeTransitionResult {
        requestedModes.append(mode)
        return transitionResult ?? .succeeded(mode)
    }

    func isAnswerInFlight() async -> Bool { inFlight }

    func resetContext() async { resetCount += 1 }

    func answerNow() async { answerNowCount += 1 }
}

struct ManualFeeds {
    let feeds: CompanionDomainFeeds
    let mode: AsyncStream<ModeState>.Continuation
    let answers: AsyncStream<AnswerStreamUpdate>.Continuation
    let transcripts: AsyncStream<TranscriptEvent>.Continuation
    let levels: AsyncStream<AudioLevel>.Continuation
    let notices: AsyncStream<CaptureNotice>.Continuation

    init() {
        let mode = AsyncStream<ModeState>.makeStream()
        let answers = AsyncStream<AnswerStreamUpdate>.makeStream()
        let transcripts = AsyncStream<TranscriptEvent>.makeStream()
        let levels = AsyncStream<AudioLevel>.makeStream()
        let notices = AsyncStream<CaptureNotice>.makeStream()
        feeds = CompanionDomainFeeds(modeStates: mode.stream, answers: answers.stream, transcripts: transcripts.stream, levels: levels.stream, notices: notices.stream)
        self.mode = mode.continuation
        self.answers = answers.continuation
        self.transcripts = transcripts.continuation
        self.levels = levels.continuation
        self.notices = notices.continuation
    }
}

actor FakeSystemAudioCapturing: SystemAudioCapturing {
    private let stream: AsyncStream<PCMAudioFrame>
    private let continuation: AsyncStream<PCMAudioFrame>.Continuation

    init() {
        (stream, continuation) = AsyncStream<PCMAudioFrame>.makeStream()
    }

    func start(scope: SystemAudioScope) async throws -> SystemAudioCaptureStart {
        SystemAudioCaptureStart(frames: stream, effectiveScope: scope)
    }

    func stop() async {
        continuation.finish()
    }
}

actor FakeMicrophoneCapturing: MicrophoneCapturing {
    func start(options: MicrophoneCaptureOptions) async throws -> AsyncStream<PCMAudioFrame> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}

struct NoLatency: LatencyRecording {
    func record(_ metric: LatencyMetric) async {}
}

final class StaticCredential: RealtimeCredentialProviding, Sendable {
    func currentCredential() async throws -> RealtimeCredential {
        RealtimeCredential(apiKey: "test-api-key")
    }
}

final class TestSocket: Sendable {
    let task: URLSessionWebSocketTask

    init(port: UInt16) {
        task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        task.resume()
    }

    func send(_ command: ClientCommand) async throws {
        let data = try CompanionCodec.encode(command)
        try await task.send(.string(String(data: data, encoding: .utf8)!))
    }

    func next() async throws -> ServerEnvelope {
        let task = self.task
        return try await withTimeout {
            switch try await task.receive() {
            case .string(let text): return try CompanionCodec.decodeServer(Data(text.utf8))
            case .data(let data): return try CompanionCodec.decodeServer(data)
            @unknown default: throw TimedOut()
            }
        }
    }

    func next(where predicate: @Sendable (ServerEvent) -> Bool) async throws -> ServerEnvelope {
        while true {
            let envelope = try await next()
            if predicate(envelope.event) { return envelope }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
