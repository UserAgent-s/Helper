import Foundation

public actor ModeCoordinator: ModeControlling {
    private var state: ModeState = .initialPassive {
        didSet { stateBroadcaster.yield(state) }
    }
    private let controllers: [AppMode: any ModeController]
    private let latencyRecording: (any LatencyRecording)?
    private var tail: Task<ModeTransitionResult, Never>?
    private var activeFailureWatcher: Task<Void, Never>?
    private(set) var transitionLog: [ModeTransition] = []

    private let stateBroadcaster = AsyncBroadcaster<ModeState>(replayLatest: true, initial: .initialPassive)

    public init(controllers: [AppMode: any ModeController], latencyRecording: (any LatencyRecording)? = nil) {
        precondition(controllers[.passive] == nil, "passive не имеет ModeController")
        self.controllers = controllers
        self.latencyRecording = latencyRecording
    }

    public var currentMode: AppMode {
        get async { state.mode }
    }

    public var currentState: ModeState {
        get async { state }
    }

    nonisolated public func stateUpdates(subscriber: String = #fileID) -> AsyncStream<ModeState> {
        stateBroadcaster.subscribe(subscriber)
    }

    public func history() async -> [ModeTransition] {
        transitionLog
    }

    public func requestTransition(to mode: AppMode) async -> ModeTransitionResult {
        await requestTransition(to: mode, reason: "user")
    }

    @discardableResult
    public func requestTransition(to mode: AppMode, reason: String) async -> ModeTransitionResult {
        let priorTail = tail
        let newTail = Task { () -> ModeTransitionResult in
            _ = await priorTail?.value
            return await self.performTransition(to: mode, reason: reason)
        }
        tail = newTail
        return await newTail.value
    }

    public func shutdown(timeout: Duration = .seconds(30)) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumer = SingleResume(continuation)
            let workTask = Task { [self] in
                _ = await self.requestTransition(to: .passive, reason: "app_termination")
                resumer.resume()
            }
            Task {
                try? await Task.sleep(for: timeout)
                workTask.cancel()
                resumer.resume()
            }
        }
    }

    private func performTransition(to mode: AppMode, reason: String) async -> ModeTransitionResult {
        let correlationID = UUID()
        let from = state.mode

        if from == mode, state.phase == .active {
            return .succeeded(mode)
        }
        if from == mode, mode == .passive {
            return .succeeded(.passive)
        }

        transitionLog.append(ModeTransition(from: from, to: mode, reason: reason, correlationID: correlationID))

        activeFailureWatcher?.cancel()
        activeFailureWatcher = nil

        if from != .passive, let currentController = controllers[from] {
            state = ModeState(mode: from, phase: .stopping, startedAt: state.startedAt, userFacingError: nil)
            let stopStartedAt = Date()
            await currentController.stop()
            await latencyRecording?.record(.modeStopMs(Int(Date().timeIntervalSince(stopStartedAt) * 1000)))
        }

        state = .initialPassive

        guard mode != .passive else {
            return .succeeded(.passive)
        }

        guard let controller = controllers[mode] else {
            let reason = "no controller registered for \(mode)"
            state = ModeState(mode: .passive, phase: .idle, startedAt: nil, userFacingError: .noControllerRegistered)
            return .failedToPassive(reason: reason)
        }

        state = ModeState(mode: mode, phase: .starting, startedAt: nil, userFacingError: nil)

        do {
            try await controller.start()
        } catch {
            await controller.stop()
            let failureReason: ModeFailureReason
            if let convertible = error as? any PermissionDeniedConvertible, let kind = convertible.deniedPermissionKind {
                failureReason = .permissionDenied(kind)
            } else if let convertible = error as? any TargetApplicationNotRunningConvertible, let bundleID = convertible.notRunningTargetApplicationBundleID {
                failureReason = .targetApplicationNotRunning(bundleID: bundleID)
            } else {
                failureReason = .unknown
            }
            state = ModeState(mode: .passive, phase: .idle, startedAt: nil, userFacingError: failureReason)
            return .failedToPassive(reason: "\(error)")
        }

        state = ModeState(mode: mode, phase: .active, startedAt: Date(), userFacingError: nil)
        watchFailures(of: controller)
        return .succeeded(mode)
    }

    private func watchFailures(of controller: any ModeController) {
        activeFailureWatcher = Task { [weak self] in
            for await reason in controller.failures() {
                if Task.isCancelled { return }
                _ = await self?.requestTransition(to: .passive, reason: "runtime_failure: \(reason)")
                return
            }
        }
    }
}

private final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<Void, Never>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let shouldResume = !didResume
        didResume = true
        lock.unlock()
        if shouldResume {
            continuation.resume()
        }
    }
}
