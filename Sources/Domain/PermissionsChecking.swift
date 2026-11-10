public enum PermissionStatus: Sendable, Equatable {
    case authorized
    case denied
    case notDetermined
}

public enum PermissionKind: Sendable, Equatable {
    case screenRecording
    case microphone
    case accessibility
}

public protocol PermissionsChecking: Sendable {
    func status(for kind: PermissionKind) async -> PermissionStatus
    func request(_ kind: PermissionKind) async -> PermissionStatus
}
