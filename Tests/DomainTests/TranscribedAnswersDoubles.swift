import Foundation
@testable import Domain

enum SpeechAudio {
    static let sampleRate = 16_000

    static func speech(ms: Int, amplitude: Int16 = 9_000, marker: Int16? = nil) -> PCMAudioFrame {
        let count = sampleRate * ms / 1000
        var samples = (0..<count).map { $0 % 2 == 0 ? amplitude : -amplitude }
        if let marker, !samples.isEmpty { samples[0] = marker }
        return PCMAudioFrame(samples: samples, sampleRate: sampleRate, channelCount: 1, capturedAt: Date(), source: .systemAudio)
    }

    static func silence(ms: Int) -> PCMAudioFrame {
        PCMAudioFrame(samples: Array(repeating: 0, count: sampleRate * ms / 1000), sampleRate: sampleRate, channelCount: 1, capturedAt: Date(), source: .systemAudio)
    }

    static func utterance(speechMs: Int = 600, pauseMs: Int = 800, chunkMs: Int = 100) -> [PCMAudioFrame] {
        Array(repeating: speech(ms: chunkMs), count: speechMs / chunkMs) + Array(repeating: silence(ms: chunkMs), count: pauseMs / chunkMs)
    }
}

actor FakeSpeechRecognizer: SpeechFragmentRecognizing {
    private var scripted: [String]
    private(set) var prepareCallCount = 0
    private(set) var recognizeCallCount = 0
    var prepareError: TestError?
    var recognizeDelay: Duration?
    var failNextRecognition = false

    init(texts: [String] = []) {
        scripted = texts
    }

    func setTexts(_ texts: [String]) { scripted = texts }
    func setPrepareError(_ error: TestError?) { prepareError = error }
    func setRecognizeDelay(_ delay: Duration?) { recognizeDelay = delay }
    func setFailNextRecognition() { failNextRecognition = true }

    func prepare() async throws {
        prepareCallCount += 1
        if let prepareError { throw prepareError }
    }

    func recognize(_ frames: [PCMAudioFrame]) async throws -> String {
        recognizeCallCount += 1
        if let recognizeDelay { try? await Task.sleep(for: recognizeDelay) }
        if failNextRecognition {
            failNextRecognition = false
            throw TestError(message: "recognition failed")
        }
        return scripted.isEmpty ? "" : scripted.removeFirst()
    }
}

struct ScriptedAnswer: Sendable {
    var events: [TextAnswerEvent]
    var error: Error?
    var delayBetweenEvents: Duration = .zero
    var ignoresCancellation = false

    static func text(_ chunks: [String], usage: ProviderUsage? = ProviderUsage(inputTokens: 100, outputTokens: 20)) -> ScriptedAnswer {
        var events: [TextAnswerEvent] = [.started(servedModel: nil)]
        events += chunks.map { .textDelta($0) }
        if let usage { events.append(.usage(usage)) }
        events.append(.completed(stopReason: "end_turn"))
        return ScriptedAnswer(events: events)
    }

    static func failure(_ error: AnswerProviderError) -> ScriptedAnswer {
        ScriptedAnswer(events: [], error: error)
    }
}

final class FakeTextAnswerGenerator: TextAnswerGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [ScriptedAnswer]
    private var _requests: [TextAnswerRequest] = []
    private var _cancelledCount = 0

    init(scripts: [ScriptedAnswer] = []) {
        self.scripts = scripts
    }

    var requests: [TextAnswerRequest] { lock.withLock { _requests } }
    var cancelledCount: Int { lock.withLock { _cancelledCount } }

    func enqueue(_ script: ScriptedAnswer) {
        lock.withLock { scripts.append(script) }
    }

    func streamAnswer(_ request: TextAnswerRequest) -> AsyncThrowingStream<TextAnswerEvent, Error> {
        let script: ScriptedAnswer = lock.withLock {
            _requests.append(request)
            return scripts.isEmpty ? ScriptedAnswer.text(["ok"]) : scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in script.events {
                    if script.delayBetweenEvents > .zero {
                        if script.ignoresCancellation {
                            let deadline = ContinuousClock.now.advanced(by: script.delayBetweenEvents)
                            while ContinuousClock.now < deadline { await Task.yield() }
                        } else {
                            try? await Task.sleep(for: script.delayBetweenEvents)
                        }
                    }
                    if Task.isCancelled, !script.ignoresCancellation { break }
                    continuation.yield(event)
                }
                if let error = script.error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason {
                    self?.lock.withLock { self?._cancelledCount += 1 }
                    if !script.ignoresCancellation { task.cancel() }
                }
            }
        }
    }
}

actor InMemoryQuestionAnswerRepository: QuestionAnswerRepository {
    private(set) var saved: [UUID: QuestionAnswerPair] = [:]

    func save(_ pair: QuestionAnswerPair) async throws { saved[pair.id] = pair }
    func delete(id: UUID) async throws { saved[id] = nil }
    func deleteAll() async throws { saved.removeAll() }
    func history(limit: Int) async throws -> [QuestionAnswerPair] { Array(saved.values.prefix(limit)) }
    func search(query: String) async throws -> [QuestionAnswerPair] { [] }
}

func eventually(timeout: Duration = .seconds(2), _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

actor RestartableSystemAudio: SystemAudioCapturing {
    private var continuation: AsyncStream<PCMAudioFrame>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    var startCalled: Bool { startCount > 0 }
    var stopCalled: Bool { stopCount > 0 }
    var isCapturing: Bool { continuation != nil }

    func start(targetApplicationBundleID: String?) async throws -> AsyncStream<PCMAudioFrame> {
        startCount += 1
        let (stream, continuation) = AsyncStream<PCMAudioFrame>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() async {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func emit(_ frame: PCMAudioFrame) {
        continuation?.yield(frame)
    }
}
