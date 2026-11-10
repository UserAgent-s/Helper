import Domain
import Foundation
import Testing
@testable import ScreenContext

private final class FakeAX: AccessibilityProviding, @unchecked Sendable {
    var trusted = true
    var app: FrontmostApplication? = FrontmostApplication(pid: 42, bundleID: "com.microsoft.VSCode", name: "Code", isElectron: true)
    var texts: FocusedTexts? = FocusedTexts(selected: "let x = 1", value: "file body", windowTitle: "main.swift")
    private(set) var enableCalls: [(Int32, Bool)] = []
    private(set) var excluded: [String?] = []

    func isTrusted() -> Bool { trusted }
    func frontmostApplication(excludingBundleID: String?) -> FrontmostApplication? { excluded.append(excludingBundleID); return app }
    func focusedTexts(pid: Int32) -> FocusedTexts? { texts }
    func enableAccessibilityTree(pid: Int32, electron: Bool) -> Bool { enableCalls.append((pid, electron)); return true }
}

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000)
}

@Suite struct AccessibilityTextReaderTests {
    @Test func selectionHasPriorityOverFocusedValue() async throws {
        let ax = FakeAX()
        let reader = AccessibilityTextReader(provider: ax, ownBundleID: "com.local.UserAgent057")
        let captured = try await reader.read().get()
        #expect(captured.text == "let x = 1")
        #expect(captured.source == .selection)
        #expect(captured.application == "Code")
        #expect(captured.windowTitle == "main.swift")
        #expect(!captured.truncated)
        #expect(ax.excluded == ["com.local.UserAgent057"])
    }

    @Test func fallsBackToFocusedValueWhenNothingSelected() async throws {
        let ax = FakeAX()
        ax.texts = FocusedTexts(selected: "  \n", value: "Ошибка: NullPointerException", windowTitle: nil)
        let captured = try await AccessibilityTextReader(provider: ax).read().get()
        #expect(captured.source == .focusedValue)
        #expect(captured.text == "Ошибка: NullPointerException")
    }

    @Test func clipsTo8000CharactersAndNormalizes() async throws {
        let ax = FakeAX()
        ax.texts = FocusedTexts(selected: nil, value: String(repeating: "e\u{0301}", count: 9_000), windowTitle: nil)
        let captured = try await AccessibilityTextReader(provider: ax).read().get()
        #expect(captured.text.count == 8_000)
        #expect(captured.truncated)
        #expect(captured.text.unicodeScalars.first == "\u{00E9}")
    }

    @Test func missingPermissionIsAnExplicitFailure() async {
        let ax = FakeAX()
        ax.trusted = false
        let result = await AccessibilityTextReader(provider: ax).read()
        #expect(result == .failure(.permissionDenied(.accessibility)))
        #expect(ScreenCaptureFailure.permissionDenied(.accessibility).code == "accessibility_permission_missing")
        #expect(ax.excluded.isEmpty)
    }

    @Test func noAppOrNoTextFailures() async {
        let ax = FakeAX()
        ax.texts = FocusedTexts(selected: nil, value: nil, windowTitle: "w")
        #expect(await AccessibilityTextReader(provider: ax).read() == .failure(.noText))
        ax.app = nil
        #expect(await AccessibilityTextReader(provider: ax).read() == .failure(.noFrontmostApplication))
    }

    @Test func chromiumAndElectronTreeIsEnabledAtMostOncePerMinute() async throws {
        let ax = FakeAX()
        let clock = Clock()
        let reader = AccessibilityTextReader(provider: ax, now: { clock.now })
        _ = await reader.read()
        _ = await reader.read()
        #expect(ax.enableCalls.count == 1)
        #expect(ax.enableCalls.first?.1 == true)
        clock.now = clock.now.addingTimeInterval(61)
        _ = await reader.read()
        #expect(ax.enableCalls.count == 2)
        ax.app = FrontmostApplication(pid: 7, bundleID: "com.google.Chrome", name: "Chrome")
        _ = await reader.read()
        #expect(ax.enableCalls.last?.0 == 7)
        #expect(ax.enableCalls.last?.1 == false)
        ax.app = FrontmostApplication(pid: 9, bundleID: "com.apple.Terminal", name: "Terminal")
        _ = await reader.read()
        #expect(ax.enableCalls.count == 3)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["USERAGENT057_HARDWARE"] == "1"))
struct AccessibilityHardwareProbe {
    @Test func readsFrontmostWithinBudget() async {
        let provider = SystemAccessibilityProvider()
        guard provider.isTrusted() else {
            print("HARDWARE accessibility: not trusted for this test host")
            return
        }
        let reader = AccessibilityTextReader(provider: provider, ownBundleID: nil)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await reader.read()
        let elapsed = clock.now - start
        switch result {
        case .success(let captured):
            print("HARDWARE accessibility: app=\(captured.application ?? "?") source=\(captured.source.rawValue) chars=\(captured.text.count) ms=\(elapsed)")
        case .failure(let failure):
            print("HARDWARE accessibility: failure=\(failure.code) ms=\(elapsed)")
        }
        #expect(elapsed < .milliseconds(500))
    }
}
