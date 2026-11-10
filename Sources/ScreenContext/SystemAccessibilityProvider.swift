import AppKit
import ApplicationServices
import Domain
import Foundation

public final class LastActiveApplicationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var last: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private let ownBundleID: String?

    public init(ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.ownBundleID = ownBundleID
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != ownBundleID {
            last = front
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.note(app)
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func note(_ app: NSRunningApplication) {
        guard app.bundleIdentifier != ownBundleID, app.activationPolicy == .regular else { return }
        lock.withLock { last = app }
    }

    public var application: NSRunningApplication? {
        lock.withLock { last?.isTerminated == false ? last : nil }
    }
}

public struct SystemAccessibilityProvider: AccessibilityProviding {
    public static let messagingTimeout: Float = 0.2

    private let tracker: LastActiveApplicationTracker

    public init(tracker: LastActiveApplicationTracker = LastActiveApplicationTracker()) {
        self.tracker = tracker
    }

    public func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public func frontmostApplication(excludingBundleID: String?) -> FrontmostApplication? {
        var candidate = NSWorkspace.shared.frontmostApplication
        if candidate == nil || candidate?.bundleIdentifier == excludingBundleID {
            candidate = tracker.application
        }
        guard let app = candidate, app.bundleIdentifier != excludingBundleID else { return nil }
        let electron = app.bundleURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) } ?? false
        return FrontmostApplication(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName, isElectron: electron)
    }

    public func focusedTexts(pid: Int32) -> FocusedTexts? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        let window: AXUIElement? = copyAttribute(application, kAXFocusedWindowAttribute)
        let title: String? = window.flatMap { copyAttribute($0, kAXTitleAttribute) }
        guard let element: AXUIElement = copyAttribute(application, kAXFocusedUIElementAttribute) else {
            return title == nil ? nil : FocusedTexts(selected: nil, value: nil, windowTitle: title)
        }
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        let selected: String? = copyAttribute(element, kAXSelectedTextAttribute)
        let value: String? = copyAttribute(element, kAXValueAttribute)
        return FocusedTexts(selected: selected, value: value, windowTitle: title)
    }

    public func enableAccessibilityTree(pid: Int32, electron: Bool) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        let manual = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if manual == .success { return true }
        guard !electron else { return false }
        return AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success
    }

    private func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        return value as? T
    }
}
