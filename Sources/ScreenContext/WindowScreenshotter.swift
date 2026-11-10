import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct WindowSnapshot: @unchecked Sendable {
    public let image: CGImage
    public let application: String?
    public let bundleID: String?
    public let windowTitle: String?
    public let isWholeDisplay: Bool
}

public enum WindowCaptureError: Error, Sendable, Equatable {
    case permissionDenied
    case noWindow
    case failed(String)
}

public protocol WindowCapturing: Sendable {
    func hasPermission() -> Bool
    func captureFrontWindow(excludingBundleID: String?) async throws -> WindowSnapshot
}

public struct WindowScreenshotter: WindowCapturing {
    private let tracker: LastActiveApplicationTracker

    public init(tracker: LastActiveApplicationTracker = LastActiveApplicationTracker()) {
        self.tracker = tracker
    }

    public func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func captureFrontWindow(excludingBundleID: String?) async throws -> WindowSnapshot {
        guard hasPermission() else { throw WindowCaptureError.permissionDenied }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw WindowCaptureError.failed("shareable_content")
        }
        var target = NSWorkspace.shared.frontmostApplication
        if target == nil || target?.bundleIdentifier == excludingBundleID {
            target = tracker.application
        }
        let windows = content.windows.filter { window in
            window.windowLayer == 0 && window.isOnScreen && window.frame.width > 40 && window.frame.height > 40
                && window.owningApplication?.bundleIdentifier != excludingBundleID
        }
        let pick = Self.pickWindow(windows.map { WindowCandidate(pid: $0.owningApplication?.processID ?? -1, area: $0.frame.width * $0.frame.height) }, pid: target?.processIdentifier)
        if let index = pick {
            let window = windows[index]
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await Self.capture(filter)
            return WindowSnapshot(image: image, application: window.owningApplication?.applicationName, bundleID: window.owningApplication?.bundleIdentifier, windowTitle: window.title, isWholeDisplay: false)
        }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw WindowCaptureError.noWindow }
        let own = content.applications.filter { $0.bundleIdentifier == excludingBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let image = try await Self.capture(filter)
        return WindowSnapshot(image: image, application: target?.localizedName, bundleID: target?.bundleIdentifier, windowTitle: nil, isWholeDisplay: true)
    }

    struct WindowCandidate: Equatable {
        let pid: Int32
        let area: Double
    }

    static func pickWindow(_ candidates: [WindowCandidate], pid: Int32?) -> Int? {
        guard let pid else { return nil }
        return candidates.firstIndex { $0.pid == pid }
    }

    private static func capture(_ filter: SCContentFilter) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        configuration.width = max(1, Int(filter.contentRect.width * scale))
        configuration.height = max(1, Int(filter.contentRect.height * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw WindowCaptureError.failed("screenshot")
        }
    }
}
