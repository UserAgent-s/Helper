import Foundation

public enum SessionState: Sendable, Equatable {
    case idle
    case active(sessionID: SessionID, startedAt: Date, mode: SessionSpanMode?)
    case finalizing(sessionID: SessionID)

    public var sessionID: SessionID? {
        switch self {
        case .idle: nil
        case .active(let id, _, _): id
        case .finalizing(let id): id
        }
    }
}

public enum SessionStopReason: String, Sendable, Equatable {
    case user
    case idleTimeout
}

public enum SessionEvent: Sendable, Equatable {
    case started(SessionID, resumed: Bool)
    case stopped(SessionID, reason: SessionStopReason)
    case bookmarkAdded(SessionBookmark)
    case bookmarkRemoved(id: String, sessionID: SessionID)
}

public enum StarToggleResult: Sendable, Equatable {
    case starred(SessionBookmark)
    case unstarred(questionAnswerID: UUID)
    case noCompletedAnswer
    case noActiveSession
}

public protocol SessionControlling: Sendable {
    var currentState: SessionState { get async }
    func stateUpdates(subscriber: String) -> AsyncStream<SessionState>
    func events(subscriber: String) -> AsyncStream<SessionEvent>
    @discardableResult func start() async throws -> SessionID
    func stop() async
    @discardableResult func resume(sessionID: SessionID) async throws -> SessionID
    func toggleStarLastAnswer() async throws -> StarToggleResult
    func markMoment(note: String?) async throws -> SessionBookmark?
}

public protocol SessionModeDriving: Sendable {
    func requestTransition(to mode: AppMode) async -> ModeTransitionResult
    func modeStates(subscriber: String) -> AsyncStream<ModeState>
    var currentModeState: ModeState { get async }
}

extension ModeCoordinator: SessionModeDriving {
    nonisolated public func modeStates(subscriber: String) -> AsyncStream<ModeState> {
        stateUpdates(subscriber: subscriber)
    }

    public var currentModeState: ModeState {
        get async { await currentState }
    }
}
