import Foundation

public protocol SleepPreventing: Sendable {
    func begin(reason: String) -> any SleepPreventionToken
}

public protocol SleepPreventionToken: Sendable {
    func end()
}

public struct ProcessInfoSleepPreventing: SleepPreventing {
    public init() {}

    public func begin(reason: String) -> any SleepPreventionToken {
        ProcessActivityToken(activity: ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: reason))
    }
}

final class ProcessActivityToken: SleepPreventionToken, @unchecked Sendable {
    private let lock = NSLock()
    private var activity: (any NSObjectProtocol)?

    init(activity: any NSObjectProtocol) {
        self.activity = activity
    }

    func end() {
        let current = lock.withLock { () -> (any NSObjectProtocol)? in
            defer { activity = nil }
            return activity
        }
        if let current { ProcessInfo.processInfo.endActivity(current) }
    }
}

public actor ModeActivityGuard {
    public static let heldModes: Set<AppMode> = [.answers, .recording]

    private let preventing: any SleepPreventing
    private var token: (any SleepPreventionToken)?
    private var task: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var modeHold: AppMode?
    private var sessionHold = false

    public init(preventing: any SleepPreventing = ProcessInfoSleepPreventing()) {
        self.preventing = preventing
    }

    public var isHolding: Bool {
        token != nil
    }

    public func start(states: AsyncStream<ModeState>) {
        guard task == nil else { return }
        task = Task { [weak self] in
            for await state in states {
                await self?.apply(state)
            }
        }
    }

    public func observeSessions(_ states: AsyncStream<SessionState>) {
        guard sessionTask == nil else { return }
        sessionTask = Task { [weak self] in
            for await state in states {
                await self?.apply(state)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        sessionTask?.cancel()
        sessionTask = nil
        modeHold = nil
        sessionHold = false
        release()
    }

    func apply(_ state: ModeState) {
        let shouldHold = Self.heldModes.contains(state.mode) && (state.phase == .starting || state.phase == .active)
        modeHold = shouldHold ? state.mode : nil
        reconcile()
    }

    func apply(_ state: SessionState) {
        if case .idle = state {
            sessionHold = false
        } else {
            sessionHold = true
        }
        reconcile()
    }

    private func reconcile() {
        let reason: String? = if let modeHold { "UserAgent057 \(modeHold) mode" } else if sessionHold { "UserAgent057 session" } else { nil }
        if let reason, token == nil {
            token = preventing.begin(reason: reason)
        } else if reason == nil {
            release()
        }
    }

    private func release() {
        token?.end()
        token = nil
    }
}
