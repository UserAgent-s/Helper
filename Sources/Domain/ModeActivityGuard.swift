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

    public func stop() {
        task?.cancel()
        task = nil
        release()
    }

    func apply(_ state: ModeState) {
        let shouldHold = Self.heldModes.contains(state.mode) && (state.phase == .starting || state.phase == .active)
        if shouldHold, token == nil {
            token = preventing.begin(reason: "UserAgent057 \(state.mode) mode")
        } else if !shouldHold {
            release()
        }
    }

    private func release() {
        token?.end()
        token = nil
    }
}
