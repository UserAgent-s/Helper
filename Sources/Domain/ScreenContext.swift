import Foundation

public enum ScreenTextSource: String, Sendable, Equatable {
    case selection
    case focusedValue = "focused_value"
    case ocr
}

public struct CapturedScreenText: Sendable, Equatable {
    public let text: String
    public let source: ScreenTextSource
    public let application: String?
    public let bundleID: String?
    public let windowTitle: String?
    public let truncated: Bool
    public let capturedAt: Date
    public let durationMs: Int

    public init(text: String, source: ScreenTextSource, application: String?, bundleID: String?, windowTitle: String?, truncated: Bool, capturedAt: Date, durationMs: Int) {
        self.text = text
        self.source = source
        self.application = application
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.truncated = truncated
        self.capturedAt = capturedAt
        self.durationMs = durationMs
    }
}

public enum ScreenCaptureFailure: Error, Sendable, Equatable {
    case permissionDenied(PermissionKind)
    case noFrontmostApplication
    case noText
    case timedOut
    case failed(String)

    public var code: String {
        switch self {
        case .permissionDenied(.accessibility): "accessibility_permission_missing"
        case .permissionDenied(.screenRecording): "screen_recording_permission_missing"
        case .permissionDenied: "permission_missing"
        case .noFrontmostApplication: "no_frontmost_application"
        case .noText: "no_screen_text"
        case .timedOut: "screen_capture_timeout"
        case .failed: "screen_capture_failed"
        }
    }
}

public enum ScreenCaptureKind: String, Sendable, Equatable, CaseIterable {
    case auto
    case selection
    case window
}

public protocol ScreenTextCapturing: Sendable {
    func capture(_ kind: ScreenCaptureKind) async -> Result<CapturedScreenText, ScreenCaptureFailure>
}

public enum ScreenTextLimits {
    public static let maxCharacters = 8_000

    public static func clip(_ text: String) -> (text: String, truncated: Bool) {
        let normalized = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxCharacters else { return (normalized, false) }
        return (String(normalized.prefix(maxCharacters)), true)
    }
}
