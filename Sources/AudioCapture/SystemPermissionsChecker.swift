import AVFoundation
import ApplicationServices
import CoreGraphics
import Domain

public struct SystemPermissionsChecker: PermissionsChecking {
    public init() {}

    public func status(for kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .screenRecording:
            Self.mapScreenCaptureAccess(CGPreflightScreenCaptureAccess())
        case .microphone:
            Self.mapAVAuthorizationStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        case .accessibility:
            AXIsProcessTrusted() ? .authorized : .notDetermined
        }
    }

    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .screenRecording:
            return Self.mapScreenCaptureAccess(CGRequestScreenCaptureAccess())
        case .microphone:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? .authorized : .denied
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .authorized : .denied
        }
    }

    static func mapScreenCaptureAccess(_ granted: Bool) -> PermissionStatus {
        granted ? .authorized : .denied
    }

    static func mapAVAuthorizationStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }
}
