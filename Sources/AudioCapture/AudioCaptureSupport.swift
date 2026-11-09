import Domain

public enum AudioCaptureOutputFormat: Sendable {
    case realtimeStreaming
    case whisperTranscription

    var targetSampleRate: Int {
        switch self {
        case .realtimeStreaming: RealtimeAudioFormatConverter.targetSampleRate
        case .whisperTranscription: WhisperAudioFormatConverter.targetSampleRate
        }
    }
}

public enum AudioCaptureError: Error, Sendable, Equatable {
    case permissionDenied(PermissionKind)
    case noDisplayAvailable
    case targetApplicationNotFound(String)
    case microphoneDeviceUnavailable(String)
    case systemAudioTapFailed(String)
}

extension AudioCaptureError: PermissionDeniedConvertible {
    public var deniedPermissionKind: PermissionKind? {
        if case .permissionDenied(let kind) = self { return kind }
        return nil
    }
}

extension AudioCaptureError: TargetApplicationNotRunningConvertible {
    public var notRunningTargetApplicationBundleID: String? {
        if case .targetApplicationNotFound(let bundleID) = self { return bundleID }
        return nil
    }
}
