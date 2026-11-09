import AppKit
import Carbon.HIToolbox
import Domain
import Foundation
import OverlayReducer
import Testing
@testable import UserAgent057

private actor ScriptedSessions: SessionControlling {
    private var state: SessionState = .idle
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var starResult: StarToggleResult = .noCompletedAnswer
    private let startDelay: Duration
    private let broadcaster: AsyncStream<SessionState>
    private let continuation: AsyncStream<SessionState>.Continuation

    init(startDelay: Duration = .zero) {
        self.startDelay = startDelay
        (broadcaster, continuation) = AsyncStream<SessionState>.makeStream()
    }

    func setStar(_ result: StarToggleResult) { starResult = result }

    var currentState: SessionState { state }

    nonisolated func stateUpdates(subscriber: String) -> AsyncStream<SessionState> { broadcaster }

    nonisolated func events(subscriber: String) -> AsyncStream<SessionEvent> { AsyncStream { $0.finish() } }

    func start() async throws -> SessionID {
        startCount += 1
        if startDelay > .zero { try? await Task.sleep(for: startDelay) }
        let id = SessionID()
        update(.active(sessionID: id, startedAt: Date(), mode: .answers))
        return id
    }

    func stop() async {
        stopCount += 1
        update(.idle)
    }

    func resume(sessionID: SessionID) async throws -> SessionID { sessionID }

    func toggleStarLastAnswer() async throws -> StarToggleResult { starResult }

    func markMoment(note: String?) async throws -> SessionBookmark? {
        guard let id = state.sessionID else { return nil }
        return SessionBookmark(sessionID: id, kind: .moment, markedAt: Date())
    }

    private func update(_ next: SessionState) {
        state = next
        continuation.yield(next)
    }
}

private struct QuietSystemAudio: SystemAudioCapturing {
    func start(scope: SystemAudioScope) async throws -> SystemAudioCaptureStart {
        SystemAudioCaptureStart(frames: AsyncStream { $0.finish() }, effectiveScope: scope)
    }
    func stop() async {}
}

private struct QuietMicrophone: MicrophoneCapturing {
    func start(options: MicrophoneCaptureOptions) async throws -> AsyncStream<PCMAudioFrame> { AsyncStream { $0.finish() } }
    func stop() async {}
}

private struct QuietResponder: LiveResponder {
    var capabilities: ProviderCapabilities { [.manualResponse, .streamingText] }
    func injectContext(_ context: InjectedContext) async throws {}
    func start(instructions: String) async throws {}
    func appendAudio(_ frame: PCMAudioFrame) async {}
    func events() -> AsyncStream<RealtimeAnswerEvent> { AsyncStream { $0.finish() } }
    func forceResponse() async throws {}
    func resetContext() async {}
    func stop() async {}
}

@MainActor
@Suite struct SessionControlViewModelTests {
    @Test func toggleStartsThenStopsAndRepeatedStartIsNoOp() async throws {
        let sessions = ScriptedSessions()
        let model = SessionControlViewModel(sessions: sessions)
        await model.toggle()
        #expect(await sessions.startCount == 1)
        await model.start()
        #expect(await sessions.startCount == 1)
        for _ in 0..<100 where !model.isActive { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.isActive)
        #expect(model.startedAt != nil)
        await model.markMoment()
        #expect(model.feedback == .momentMarked)
        await model.toggle()
        #expect(await sessions.stopCount == 1)
        await model.stop()
        #expect(await sessions.stopCount == 1)
        for _ in 0..<100 where model.isActive { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.isActive)
    }

    @Test func secondToggleWhileStartingIsIgnored() async throws {
        let sessions = ScriptedSessions(startDelay: .milliseconds(100))
        let model = SessionControlViewModel(sessions: sessions)
        async let first: Void = model.toggle()
        try await Task.sleep(for: .milliseconds(20))
        await model.toggle()
        await first
        #expect(await sessions.startCount == 1)
        #expect(await sessions.stopCount == 0)
    }

    @Test func starFeedbackMapsResult() async {
        let sessions = ScriptedSessions()
        let model = SessionControlViewModel(sessions: sessions)
        await model.starLastAnswer()
        #expect(model.feedback == .noCompletedAnswer)
        await sessions.setStar(.noActiveSession)
        await model.starLastAnswer()
        #expect(model.feedback == .noActiveSession)
        await sessions.setStar(.unstarred(questionAnswerID: UUID()))
        await model.starLastAnswer()
        #expect(model.feedback == .unstarred)
    }

    @Test func sessionHotKeysToggleSessionAndStar() async throws {
        let sessions = ScriptedSessions()
        await sessions.setStar(.starred(SessionBookmark(sessionID: SessionID(), kind: .star, markedAt: Date())))
        let model = SessionControlViewModel(sessions: sessions)
        let suite = "session-hotkeys-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = OverlayPreferencesStore(defaults: defaults)
        let backend = FakeHotKeyBackend()
        let trigger = ManualAnswerTrigger()
        let answers = AnswersModeController(
            captureHub: CaptureHub(system: QuietSystemAudio(), microphone: QuietMicrophone()),
            realtime: QuietResponder(),
            answerTrigger: trigger,
            instructionsProvider: { "test" }
        )
        let overlay = AnswerOverlayViewModel(modeCoordinator: ModeCoordinator(controllers: [.answers: answers]), answersController: answers, manualAnswerTrigger: trigger)
        let controller = AnswerOverlayWindowController(viewModel: overlay, preferences: preferences, overlaySwitch: nil, registersHotKeys: false, hotKeyBackend: backend)
        defer { controller.tearDown() }

        let results = model.registerHotKeys(on: controller, preferences: preferences)
        #expect(results.allSatisfy { if case .registered = $0 { true } else { false } })
        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        let toggleID = try #require(backend.registered.first { $0.value == (UInt32(kVK_ANSI_S), modifiers) }?.key)
        let starID = try #require(backend.registered.first { $0.value == (UInt32(kVK_ANSI_B), modifiers) }?.key)

        backend.press(toggleID)
        for _ in 0..<100 where await sessions.startCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await sessions.startCount == 1)
        backend.press(starID)
        for _ in 0..<100 where model.feedback == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.feedback == .starred)
        backend.press(toggleID)
        for _ in 0..<100 where await sessions.stopCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await sessions.stopCount == 1)
    }
}
