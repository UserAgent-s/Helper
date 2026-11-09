import Testing
import Domain
import Foundation
@testable import OverlayReducer

private actor FakeSystemAudioCapturing: SystemAudioCapturing {
    private var continuation: AsyncStream<PCMAudioFrame>.Continuation?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start(scope: SystemAudioScope) async throws -> SystemAudioCaptureStart {
        startCallCount += 1
        let (stream, continuation) = AsyncStream<PCMAudioFrame>.makeStream()
        self.continuation = continuation
        return SystemAudioCaptureStart(frames: stream, effectiveScope: scope)
    }

    func stop() async {
        stopCallCount += 1
        continuation?.finish()
        continuation = nil
    }
}

private struct SilentMicrophoneCapturing: MicrophoneCapturing {
    func start() async throws -> AsyncStream<PCMAudioFrame> { AsyncStream { $0.finish() } }
    func stop() async {}
}

private actor FakeLiveResponder: LiveResponder {
    private let stream: AsyncStream<RealtimeAnswerEvent>
    private let continuation: AsyncStream<RealtimeAnswerEvent>.Continuation
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var resetContextCallCount = 0

    init() {
        (stream, continuation) = AsyncStream<RealtimeAnswerEvent>.makeStream()
    }

    nonisolated var capabilities: ProviderCapabilities { [.serverVAD, .textInjection, .manualResponse, .streamingText] }

    func injectContext(_ text: String) async throws {}

    func start(instructions: String) async throws {
        startCallCount += 1
    }

    func appendAudio(_ frame: PCMAudioFrame) async {}

    nonisolated func events() -> AsyncStream<RealtimeAnswerEvent> {
        stream
    }

    func forceResponse() async throws {}

    func resetContext() async {
        resetContextCallCount += 1
    }

    func stop() async {
        stopCallCount += 1
    }

    func emit(_ event: RealtimeAnswerEvent) {
        continuation.yield(event)
    }
}

@MainActor
@Suite struct AnswerOverlayViewModelTests {

    @Test func resettingAfterCompletedAnswerDoesNotRestartTheRealtimeSession() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let answersController = AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: SilentMicrophoneCapturing()), realtime: realtime, answerTrigger: ManualAnswerTrigger(), instructionsProvider: { "test" })
        let modeCoordinator = ModeCoordinator(controllers: [.answers: answersController])
        _ = await modeCoordinator.requestTransition(to: .answers)

        let viewModel = AnswerOverlayViewModel(modeCoordinator: modeCoordinator, answersController: answersController, manualAnswerTrigger: ManualAnswerTrigger())
        try await Task.sleep(for: .milliseconds(20))

        await realtime.emit(.responseStarted(responseID: "auto-1", trigger: .automatic))
        await realtime.emit(.textDelta(responseID: "auto-1", text: "Ответ"))
        await realtime.emit(.completed(responseID: "auto-1"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(viewModel.state.visibility == .completed)

        viewModel.resetContext()
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.state.visibility == .collectingContext)
        #expect(viewModel.state.text.isEmpty)
        #expect(await realtime.stopCallCount == 0)
        #expect(await systemAudio.stopCallCount == 0)
    }

    @Test func resettingWhileCollectingContextResetsWithoutRestartingTheSession() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let realtime = FakeLiveResponder()
        let answersController = AnswersModeController(captureHub: CaptureHub(system: systemAudio, microphone: SilentMicrophoneCapturing()), realtime: realtime, answerTrigger: ManualAnswerTrigger(), instructionsProvider: { "test" })
        let modeCoordinator = ModeCoordinator(controllers: [.answers: answersController])
        _ = await modeCoordinator.requestTransition(to: .answers)

        let viewModel = AnswerOverlayViewModel(modeCoordinator: modeCoordinator, answersController: answersController, manualAnswerTrigger: ManualAnswerTrigger())
        try await Task.sleep(for: .milliseconds(20))
        #expect(viewModel.state.visibility == .collectingContext)

        viewModel.resetContext()
        try await Task.sleep(for: .milliseconds(50))

        #expect(await realtime.stopCallCount == 0)
        #expect(await systemAudio.stopCallCount == 0)
        #expect(await realtime.resetContextCallCount == 1)
        #expect(await realtime.startCallCount == 1)
        #expect(await modeCoordinator.currentMode == .answers)
    }
}
