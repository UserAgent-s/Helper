import AppKit
import Carbon.HIToolbox
import Domain
import Foundation
import OverlayReducer
import Testing
@testable import UserAgent057

private actor HotKeySystemAudio: SystemAudioCapturing {
    private var continuation: AsyncStream<PCMAudioFrame>.Continuation?

    func start(scope: SystemAudioScope) async throws -> SystemAudioCaptureStart {
        let (stream, continuation) = AsyncStream<PCMAudioFrame>.makeStream()
        self.continuation = continuation
        return SystemAudioCaptureStart(frames: stream, effectiveScope: scope)
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }
}

private struct HotKeySilentMicrophone: MicrophoneCapturing {
    func start(options: MicrophoneCaptureOptions) async throws -> AsyncStream<PCMAudioFrame> { AsyncStream { $0.finish() } }
    func stop() async {}
}

private actor HotKeyResponder: LiveResponder {
    private let stream: AsyncStream<RealtimeAnswerEvent>
    private let continuation: AsyncStream<RealtimeAnswerEvent>.Continuation
    private(set) var forceResponseCount = 0

    init() {
        (stream, continuation) = AsyncStream<RealtimeAnswerEvent>.makeStream()
    }

    nonisolated var capabilities: ProviderCapabilities { [.serverVAD, .textInjection, .manualResponse, .streamingText] }
    func injectContext(_ context: InjectedContext) async throws {}
    func start(instructions: String) async throws {}
    func appendAudio(_ frame: PCMAudioFrame) async {}
    nonisolated func events() -> AsyncStream<RealtimeAnswerEvent> { stream }

    func forceResponse() async throws {
        forceResponseCount += 1
        continuation.yield(.responseStarted(responseID: "manual-\(forceResponseCount)", trigger: .manual))
    }

    func resetContext() async {}
    func stop() async {}
}

@MainActor
final class FakeHotKeyBackend: HotKeyBackend {
    var installCount = 0
    var uninstallCount = 0
    var registered: [UInt32: (keyCode: UInt32, modifiers: UInt32)] = [:]
    var rejectStatus: Int32?
    var dispatch: (@MainActor (UInt32) -> Void)?

    func install(dispatch: @escaping @MainActor (UInt32) -> Void) -> Bool {
        installCount += 1
        self.dispatch = dispatch
        return true
    }

    func uninstall() {
        uninstallCount += 1
        dispatch = nil
    }

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Int32 {
        if let rejectStatus { return rejectStatus }
        registered[id] = (keyCode, modifiers)
        return 0
    }

    func unregister(id: UInt32) {
        registered[id] = nil
    }

    func press(_ id: UInt32) {
        dispatch?(id)
    }
}

@MainActor
@Suite struct HotKeyTests {
    @Test func defaultsKeepOptionReturnAndOptionCommandH() {
        #expect(HotKeyAction.answerNow.defaultCombo == HotKeyCombo(keyCode: UInt16(kVK_Return), modifierFlags: .option))
        #expect(HotKeyAction.toggleOverlay.defaultCombo == HotKeyCombo(keyCode: UInt16(kVK_ANSI_H), modifierFlags: [.option, .command]))
        #expect(HotKeyAction.toggleSession.defaultCombo == nil)
        #expect(HotKeyAction.toggleScreen.defaultCombo == nil)
    }

    @Test func defaultCombosDoNotConflict() {
        let combos = HotKeyAction.allCases.compactMap(\.defaultCombo)
        #expect(Set(combos).count == combos.count)
    }

    @Test func carbonModifiersMapFromEventFlags() {
        let combo = HotKeyCombo(keyCode: 4, modifierFlags: [.option, .command, .shift, .control, .capsLock, .function])
        #expect(combo.carbonModifiers == UInt32(optionKey | cmdKey | shiftKey | controlKey))
        #expect(HotKeyCombo.forceAnswerNowDefault.carbonModifiers == UInt32(optionKey))
    }

    @Test func registerAndUnregisterGoThroughBackend() {
        let backend = FakeHotKeyBackend()
        let manager = GlobalHotKeyManager(backend: backend)
        var presses = 0
        let result = manager.register(.forceAnswerNowDefault) { presses += 1 }
        guard case .registered(let id) = result else {
            Issue.record("expected registration, got \(result)")
            return
        }
        #expect(backend.installCount == 1)
        #expect(backend.registered[id]?.keyCode == UInt32(kVK_Return))
        #expect(backend.registered[id]?.modifiers == UInt32(optionKey))

        backend.press(id)
        #expect(presses == 1)

        manager.unregister(.forceAnswerNowDefault)
        #expect(backend.registered.isEmpty)
        backend.press(id)
        #expect(presses == 1)
    }

    @Test func duplicateComboIsRejectedAndKeepsFirstAction() {
        let backend = FakeHotKeyBackend()
        let manager = GlobalHotKeyManager(backend: backend)
        var first = 0
        var second = 0
        let a = manager.register(.toggleOverlayDefault) { first += 1 }
        let b = manager.register(.toggleOverlayDefault) { second += 1 }
        #expect(b == .duplicate)
        #expect(backend.registered.count == 1)
        guard case .registered(let id) = a else { return }
        backend.press(id)
        #expect(first == 1)
        #expect(second == 0)
    }

    @Test func eachPressDispatchesExactlyOneAction() {
        let backend = FakeHotKeyBackend()
        let manager = GlobalHotKeyManager(backend: backend)
        var answers = 0
        var toggles = 0
        guard case .registered(let answerID) = manager.register(.forceAnswerNowDefault, action: { answers += 1 }),
              case .registered(let toggleID) = manager.register(.toggleOverlayDefault, action: { toggles += 1 })
        else {
            Issue.record("registration failed")
            return
        }
        #expect(answerID != toggleID)
        backend.press(answerID)
        #expect(answers == 1)
        #expect(toggles == 0)
        backend.press(toggleID)
        #expect(answers == 1)
        #expect(toggles == 1)
    }

    @Test func backendFailureIsReportedAndNotStored() {
        let backend = FakeHotKeyBackend()
        backend.rejectStatus = Int32(eventHotKeyExistsErr)
        let manager = GlobalHotKeyManager(backend: backend)
        #expect(manager.register(.forceAnswerNowDefault) {} == .unavailable(Int32(eventHotKeyExistsErr)))
        #expect(manager.registeredCombos.isEmpty)
    }

    @Test func removeAllUnregistersEverythingAndUninstalls() {
        let backend = FakeHotKeyBackend()
        let manager = GlobalHotKeyManager(backend: backend)
        manager.register(.forceAnswerNowDefault) {}
        manager.register(.toggleOverlayDefault) {}
        manager.removeAll()
        #expect(backend.registered.isEmpty)
        #expect(backend.uninstallCount == 1)
        #expect(manager.registeredCombos.isEmpty)
        manager.register(.forceAnswerNowDefault) {}
        #expect(backend.installCount == 2)
    }

    @Test func carbonBackendRegistersWithoutAccessibilityAndDetectsTakenCombo() {
        let combo = HotKeyCombo(keyCode: UInt16(kVK_F19), modifierFlags: [.control, .option, .shift, .command])
        let first = GlobalHotKeyManager()
        let second = GlobalHotKeyManager()
        defer {
            first.removeAll()
            second.removeAll()
        }
        guard case .registered = first.register(combo, action: {}) else {
            Issue.record("Carbon registration failed")
            return
        }
        #expect(second.register(combo) {} == .unavailable(Int32(eventHotKeyExistsErr)))
        first.unregister(combo)
        guard case .registered = second.register(combo, action: {}) else {
            Issue.record("combo not released after unregister")
            return
        }
    }

    @Test func answerNowHotKeyProducesExactlyOneManualResponse() async throws {
        let realtime = HotKeyResponder()
        let trigger = ManualAnswerTrigger()
        let answersController = AnswersModeController(
            captureHub: CaptureHub(system: HotKeySystemAudio(), microphone: HotKeySilentMicrophone()),
            realtime: realtime,
            answerTrigger: trigger,
            instructionsProvider: { "test" }
        )
        let modeCoordinator = ModeCoordinator(controllers: [.answers: answersController])
        _ = await modeCoordinator.requestTransition(to: .answers)
        let viewModel = AnswerOverlayViewModel(modeCoordinator: modeCoordinator, answersController: answersController, manualAnswerTrigger: trigger)
        let suite = "hotkey-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = FakeHotKeyBackend()
        let controller = AnswerOverlayWindowController(
            viewModel: viewModel,
            preferences: OverlayPreferencesStore(defaults: defaults),
            overlaySwitch: nil,
            registersHotKeys: true,
            hotKeyBackend: backend
        )
        defer { controller.tearDown() }
        try await Task.sleep(for: .milliseconds(30))

        let answerID = try #require(backend.registered.first { $0.value.keyCode == UInt32(kVK_Return) }?.key)
        backend.press(answerID)
        try await Task.sleep(for: .milliseconds(80))
        backend.press(answerID)
        try await Task.sleep(for: .milliseconds(80))

        #expect(await realtime.forceResponseCount == 1)
        _ = await modeCoordinator.requestTransition(to: .passive)
    }
}
