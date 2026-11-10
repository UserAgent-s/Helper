import Domain
import Foundation

public struct FrontmostApplication: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String?
    public let name: String?
    public let isElectron: Bool

    public init(pid: Int32, bundleID: String?, name: String?, isElectron: Bool = false) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isElectron = isElectron
    }
}

public struct FocusedTexts: Sendable, Equatable {
    public let selected: String?
    public let value: String?
    public let windowTitle: String?

    public init(selected: String?, value: String?, windowTitle: String?) {
        self.selected = selected
        self.value = value
        self.windowTitle = windowTitle
    }
}

public protocol AccessibilityProviding: Sendable {
    func isTrusted() -> Bool
    func frontmostApplication(excludingBundleID: String?) -> FrontmostApplication?
    func focusedTexts(pid: Int32) -> FocusedTexts?
    func enableAccessibilityTree(pid: Int32, electron: Bool) -> Bool
}

public actor AccessibilityTextReader {
    public static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]
    public static let enableInterval: TimeInterval = 60

    private let provider: any AccessibilityProviding
    private let ownBundleID: String?
    private let now: @Sendable () -> Date
    private var enabledAt: [Int32: Date] = [:]
    public private(set) var enableCount = 0

    public init(provider: any AccessibilityProviding, ownBundleID: String? = Bundle.main.bundleIdentifier, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.ownBundleID = ownBundleID
        self.now = now
    }

    public func read(preferSelection: Bool = true) -> Result<CapturedScreenText, ScreenCaptureFailure> {
        let started = now()
        guard provider.isTrusted() else { return .failure(.permissionDenied(.accessibility)) }
        guard let app = provider.frontmostApplication(excludingBundleID: ownBundleID) else { return .failure(.noFrontmostApplication) }
        if needsTreeEnable(app) {
            let last = enabledAt[app.pid]
            if last == nil || started.timeIntervalSince(last!) >= Self.enableInterval {
                enabledAt[app.pid] = started
                enableCount += 1
                _ = provider.enableAccessibilityTree(pid: app.pid, electron: app.isElectron)
            }
        }
        guard let texts = provider.focusedTexts(pid: app.pid) else { return .failure(.noText) }
        let selected = texts.selected.map(ScreenTextLimits.clip)
        let value = texts.value.map(ScreenTextLimits.clip)
        let chosen: (text: String, truncated: Bool, source: ScreenTextSource)?
        if let selected, !selected.text.isEmpty, preferSelection {
            chosen = (selected.text, selected.truncated, .selection)
        } else if let value, !value.text.isEmpty {
            chosen = (value.text, value.truncated, .focusedValue)
        } else if let selected, !selected.text.isEmpty {
            chosen = (selected.text, selected.truncated, .selection)
        } else {
            chosen = nil
        }
        guard let chosen else { return .failure(.noText) }
        let elapsed = Int((now().timeIntervalSince(started) * 1000).rounded())
        return .success(CapturedScreenText(text: chosen.text, source: chosen.source, application: app.name, bundleID: app.bundleID, windowTitle: texts.windowTitle, truncated: chosen.truncated, capturedAt: started, durationMs: max(0, elapsed)))
    }

    func needsTreeEnable(_ app: FrontmostApplication) -> Bool {
        app.isElectron || app.bundleID.map(Self.chromiumBundleIDs.contains) == true
    }
}
