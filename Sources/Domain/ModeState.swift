import Foundation

public enum ModePhase: Sendable, Equatable {
    case idle
    case starting
    case active
    case stopping
    case failed
}

public enum ModeFailureReason: Sendable, Equatable {
    case permissionDenied(PermissionKind)
    case targetApplicationNotRunning(bundleID: String)
    case noControllerRegistered
    case unknown
}

public protocol PermissionDeniedConvertible {
    var deniedPermissionKind: PermissionKind? { get }
}

public protocol TargetApplicationNotRunningConvertible {
    var notRunningTargetApplicationBundleID: String? { get }
}

public struct ModeState: Sendable, Equatable {
    public let mode: AppMode
    public let phase: ModePhase
    public let startedAt: Date?
    public let userFacingError: ModeFailureReason?

    public init(mode: AppMode, phase: ModePhase, startedAt: Date?, userFacingError: ModeFailureReason?) {
        self.mode = mode
        self.phase = phase
        self.startedAt = startedAt
        self.userFacingError = userFacingError
    }

    public static let initialPassive = ModeState(mode: .passive, phase: .idle, startedAt: nil, userFacingError: nil)
}

public struct ModeTransition: Sendable, Equatable {
    public let from: AppMode
    public let to: AppMode
    public let reason: String
    public let correlationID: UUID

    public init(from: AppMode, to: AppMode, reason: String, correlationID: UUID) {
        self.from = from
        self.to = to
        self.reason = reason
        self.correlationID = correlationID
    }
}

public enum AnswerTurnPhase: Sendable, Equatable {
    case collectingContext
    case automaticResponsePending
    case manualResponsePending
    case streaming
    case completed
}
