import AppKit
import CoreGraphics
import CoreText
import Domain
import Foundation
import Testing
@testable import ScreenContext

enum RenderedFixture {
    static func image(lines: [String], font: String = "Helvetica", size: CGFloat = 28, width: Int = 1400) -> CGImage {
        let lineHeight = Int(size * 1.6)
        let height = lineHeight * (lines.count + 1)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let ctFont = CTFontCreateWithName(font as CFString, size, nil)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ctFont, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 30, y: CGFloat(height - lineHeight * (index + 1)))
            CTLineDraw(ctLine, context)
        }
        return context.makeImage()!
    }
}

@Suite(.serialized) struct VisionTextRecognizerTests {
    @Test func recognizesRussianAndEnglishChatInReadingOrder() async throws {
        let image = RenderedFixture.image(lines: ["Interviewer: How do you handle retries?", "Ответ: идемпотентный ключ и очередь", "Thanks, next question"])
        let lines = try await VisionTextRecognizer().recognize(image, mode: .prose)
        let text = VisionTextRecognizer.joined(lines)
        #expect(text.contains("retries"))
        #expect(text.contains("идемпотентный"))
        let first = try #require(text.range(of: "Interviewer"))
        let second = try #require(text.range(of: "Ответ"))
        let third = try #require(text.range(of: "Thanks"))
        #expect(first.lowerBound < second.lowerBound && second.lowerBound < third.lowerBound)
    }

    @Test func recognizesCodeWithoutLanguageCorrection() async throws {
        let image = RenderedFixture.image(lines: ["func retry(_ key: String) throws {", "    let delay = backoff(attempt)", "}"], font: "Menlo")
        let text = VisionTextRecognizer.joined(try await VisionTextRecognizer().recognize(image, mode: .code))
        #expect(text.contains("func retry"))
        #expect(text.contains("backoff"))
    }

    @Test func ordersRowsTopToBottomAndColumnsLeftToRight() {
        let lines = [
            RecognizedLine(text: "bottom", minX: 0.1, minY: 0.10, height: 0.05),
            RecognizedLine(text: "top-right", minX: 0.6, minY: 0.80, height: 0.05),
            RecognizedLine(text: "top-left", minX: 0.1, minY: 0.81, height: 0.05),
            RecognizedLine(text: "middle", minX: 0.1, minY: 0.45, height: 0.05),
        ]
        let ordered = VisionTextRecognizer.ordered(lines)
        #expect(ordered.map(\.text) == ["top-left", "top-right", "middle", "bottom"])
        #expect(VisionTextRecognizer.joined(ordered) == "top-left top-right\nmiddle\nbottom")
    }
}

private final class FakeWindows: WindowCapturing, @unchecked Sendable {
    var permission = true
    var bundleID: String? = "com.google.Chrome"
    var error: WindowCaptureError?
    private(set) var excluded: [String?] = []

    func hasPermission() -> Bool { permission }

    func captureFrontWindow(excludingBundleID: String?) async throws -> WindowSnapshot {
        excluded.append(excludingBundleID)
        if let error { throw error }
        return WindowSnapshot(image: RenderedFixture.image(lines: ["x"]), application: "Chrome", bundleID: bundleID, windowTitle: "Meet", isWholeDisplay: false)
    }
}

private final class FakeRecognizer: TextRecognizing, @unchecked Sendable {
    var lines = [RecognizedLine(text: "Задача: спроектировать очередь", minX: 0, minY: 0.5, height: 0.1)]
    private(set) var modes: [RecognitionMode] = []
    func recognize(_ image: CGImage, mode: RecognitionMode) async throws -> [RecognizedLine] {
        modes.append(mode)
        return lines
    }
}

private final class FakeAXProvider: AccessibilityProviding, @unchecked Sendable {
    var trusted = true
    var texts: FocusedTexts? = FocusedTexts(selected: "выделено", value: "весь документ", windowTitle: nil)
    func isTrusted() -> Bool { trusted }
    func frontmostApplication(excludingBundleID: String?) -> FrontmostApplication? { FrontmostApplication(pid: 1, bundleID: "com.apple.Notes", name: "Notes") }
    func focusedTexts(pid: Int32) -> FocusedTexts? { texts }
    func enableAccessibilityTree(pid: Int32, electron: Bool) -> Bool { true }
}

@Suite struct ScreenTextCapturerTests {
    private func make(_ ax: FakeAXProvider, _ windows: FakeWindows, _ recognizer: FakeRecognizer) -> ScreenTextCapturer {
        ScreenTextCapturer(accessibility: AccessibilityTextReader(provider: ax, ownBundleID: "com.local.UserAgent057"), windows: windows, recognizer: recognizer, ownBundleID: "com.local.UserAgent057")
    }

    @Test func autoUsesSelectionWithoutScreenshot() async throws {
        let windows = FakeWindows()
        let result = try await make(FakeAXProvider(), windows, FakeRecognizer()).capture(.auto).get()
        #expect(result.source == .selection)
        #expect(result.text == "выделено")
        #expect(windows.excluded.isEmpty)
    }

    @Test func autoFallsBackToOCRWhenNothingSelectedAndExcludesOwnApp() async throws {
        let ax = FakeAXProvider()
        ax.texts = FocusedTexts(selected: nil, value: "весь документ", windowTitle: nil)
        let windows = FakeWindows()
        let result = try await make(ax, windows, FakeRecognizer()).capture(.auto).get()
        #expect(result.source == .ocr)
        #expect(result.text == "Задача: спроектировать очередь")
        #expect(result.windowTitle == "Meet")
        #expect(windows.excluded == ["com.local.UserAgent057"])
    }

    @Test func autoUsesFocusedValueWhenOCRUnavailable() async throws {
        let ax = FakeAXProvider()
        ax.texts = FocusedTexts(selected: nil, value: "весь документ", windowTitle: nil)
        let windows = FakeWindows()
        windows.permission = false
        let result = try await make(ax, windows, FakeRecognizer()).capture(.auto).get()
        #expect(result.source == .focusedValue)
    }

    @Test func permissionFailuresAreExplicit() async {
        let ax = FakeAXProvider()
        ax.trusted = false
        let windows = FakeWindows()
        windows.permission = false
        let capturer = make(ax, windows, FakeRecognizer())
        #expect(await capturer.capture(.auto) == .failure(.permissionDenied(.screenRecording)))
        #expect(await capturer.capture(.selection) == .failure(.permissionDenied(.accessibility)))
        #expect(await capturer.capture(.window) == .failure(.permissionDenied(.screenRecording)))
    }

    @Test func codeEditorsDisableLanguageCorrection() async throws {
        let windows = FakeWindows()
        windows.bundleID = "com.microsoft.VSCode"
        let recognizer = FakeRecognizer()
        _ = await make(FakeAXProvider(), windows, recognizer).capture(.window)
        windows.bundleID = "com.google.Chrome"
        _ = await make(FakeAXProvider(), windows, recognizer).capture(.window)
        #expect(recognizer.modes == [.code, .prose])
    }

    @Test func emptyOCRIsNoText() async {
        let recognizer = FakeRecognizer()
        recognizer.lines = []
        #expect(await make(FakeAXProvider(), FakeWindows(), recognizer).capture(.window) == .failure(.noText))
    }

    @Test func ownWindowIsNeverPicked() {
        let candidates = [WindowScreenshotter.WindowCandidate(pid: 10, area: 100), WindowScreenshotter.WindowCandidate(pid: 20, area: 900)]
        #expect(WindowScreenshotter.pickWindow(candidates, pid: 20) == 1)
        #expect(WindowScreenshotter.pickWindow(candidates, pid: 99) == nil)
        #expect(WindowScreenshotter.pickWindow(candidates, pid: nil) == nil)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["USERAGENT057_HARDWARE"] == "1"))
struct WindowOCRHardwareProbe {
    @Test func ocrOfFrontWindowWithinBudget() async {
        let windows = WindowScreenshotter()
        guard windows.hasPermission() else {
            print("HARDWARE ocr: no screen recording permission for this test host")
            return
        }
        let capturer = ScreenTextCapturer(accessibility: AccessibilityTextReader(provider: SystemAccessibilityProvider(), ownBundleID: nil), windows: windows, ownBundleID: nil)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await capturer.capture(.window)
        let elapsed = clock.now - start
        switch result {
        case .success(let captured): print("HARDWARE ocr: app=\(captured.application ?? "?") chars=\(captured.text.count) ms=\(elapsed)")
        case .failure(let failure): print("HARDWARE ocr: failure=\(failure.code) ms=\(elapsed)")
        }
        #expect(elapsed < .seconds(1.5))
    }
}
