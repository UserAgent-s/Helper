import Domain
import Foundation

public actor ScreenTextCapturer: ScreenTextCapturing {
    public static let codeBundleIDs: Set<String> = [
        "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.apple.Terminal", "com.googlecode.iterm2", "com.todesktop.230313mzl4w4u92",
        "com.jetbrains.intellij", "com.jetbrains.PhpStorm", "com.jetbrains.goland", "dev.zed.Zed", "com.sublimetext.4",
    ]

    private let accessibility: AccessibilityTextReader
    private let windows: any WindowCapturing
    private let recognizer: any TextRecognizing
    private let ownBundleID: String?
    private let now: @Sendable () -> Date

    public init(accessibility: AccessibilityTextReader, windows: any WindowCapturing, recognizer: any TextRecognizing = VisionTextRecognizer(), ownBundleID: String? = Bundle.main.bundleIdentifier, now: @escaping @Sendable () -> Date = { Date() }) {
        self.accessibility = accessibility
        self.windows = windows
        self.recognizer = recognizer
        self.ownBundleID = ownBundleID
        self.now = now
    }

    public func capture(_ kind: ScreenCaptureKind) async -> Result<CapturedScreenText, ScreenCaptureFailure> {
        switch kind {
        case .selection:
            return await accessibility.read(preferSelection: true)
        case .window:
            return await ocr()
        case .auto:
            let viaAX = await accessibility.read(preferSelection: true)
            if case .success(let captured) = viaAX, captured.source == .selection { return viaAX }
            let viaOCR = await ocr()
            switch (viaOCR, viaAX) {
            case (.success, _): return viaOCR
            case (.failure, .success): return viaAX
            case (.failure(let ocrFailure), .failure(let axFailure)):
                if case .permissionDenied = ocrFailure, case .permissionDenied = axFailure { return .failure(ocrFailure) }
                if case .permissionDenied = ocrFailure { return .failure(axFailure == .noText ? ocrFailure : axFailure) }
                return .failure(ocrFailure)
            }
        }
    }

    private func ocr() async -> Result<CapturedScreenText, ScreenCaptureFailure> {
        let started = now()
        guard windows.hasPermission() else { return .failure(.permissionDenied(.screenRecording)) }
        let snapshot: WindowSnapshot
        do {
            snapshot = try await windows.captureFrontWindow(excludingBundleID: ownBundleID)
        } catch WindowCaptureError.permissionDenied {
            return .failure(.permissionDenied(.screenRecording))
        } catch WindowCaptureError.noWindow {
            return .failure(.noFrontmostApplication)
        } catch {
            return .failure(.failed("window_capture"))
        }
        let mode: RecognitionMode = snapshot.bundleID.map(Self.codeBundleIDs.contains) == true ? .code : .prose
        let lines: [RecognizedLine]
        do {
            lines = try await recognizer.recognize(snapshot.image, mode: mode)
        } catch {
            return .failure(.failed("ocr"))
        }
        let clipped = ScreenTextLimits.clip(VisionTextRecognizer.joined(lines))
        guard !clipped.text.isEmpty else { return .failure(.noText) }
        let elapsed = Int((now().timeIntervalSince(started) * 1000).rounded())
        return .success(CapturedScreenText(text: clipped.text, source: .ocr, application: snapshot.application, bundleID: snapshot.bundleID, windowTitle: snapshot.windowTitle, truncated: clipped.truncated, capturedAt: started, durationMs: max(0, elapsed)))
    }
}
