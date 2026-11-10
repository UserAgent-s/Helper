import Foundation

public protocol ScreenContextStoring: Sendable {
    func saveScreenContext(_ context: SessionScreenContext, sessionID: SessionID) async throws
}

public struct ScreenContextCapture: Sendable, Equatable {
    public let id: String
    public let captured: CapturedScreenText
    public let asked: Bool
    public let injected: Bool
    public let sessionID: SessionID?
}

public enum ScreenContextEvent: Sendable, Equatable {
    case captured(ScreenContextCapture)
    case failed(ScreenCaptureFailure)
}

public actor ScreenContextTrigger {
    public static let expansionContextMaxAge: TimeInterval = 180

    private let capturer: any ScreenTextCapturing
    private let isAnswersActive: @Sendable () async -> Bool
    private let inject: @Sendable (InjectedContext) async throws -> Void
    private let answerNow: @Sendable () async -> Void
    private let sessions: (any SessionContextProviding)?
    private let store: (any ScreenContextStoring)?
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String
    private let redactedLog: @Sendable (String) -> Void
    private let broadcaster = AsyncBroadcaster<ScreenContextEvent>()
    private var latest: ScreenContextCapture?
    private var busy = false

    public init(
        capturer: any ScreenTextCapturing,
        isAnswersActive: @escaping @Sendable () async -> Bool,
        inject: @escaping @Sendable (InjectedContext) async throws -> Void,
        answerNow: @escaping @Sendable () async -> Void,
        sessions: (any SessionContextProviding)?,
        store: (any ScreenContextStoring)?,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> String = { "scr_" + UUID().uuidString.lowercased() },
        redactedLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.capturer = capturer
        self.isAnswersActive = isAnswersActive
        self.inject = inject
        self.answerNow = answerNow
        self.sessions = sessions
        self.store = store
        self.now = now
        self.makeID = makeID
        self.redactedLog = redactedLog
    }

    nonisolated public func events(subscriber: String) -> AsyncStream<ScreenContextEvent> {
        broadcaster.subscribe(subscriber)
    }

    @discardableResult
    public func trigger(kind: ScreenCaptureKind = .auto, ask: Bool = false) async -> Result<ScreenContextCapture, ScreenCaptureFailure> {
        guard !busy else { return .failure(.failed("busy")) }
        busy = true
        defer { busy = false }
        let result = await capturer.capture(kind)
        let captured: CapturedScreenText
        switch result {
        case .success(let value):
            captured = value
        case .failure(let failure):
            broadcaster.yield(.failed(failure))
            return .failure(failure)
        }
        var injected = false
        if await isAnswersActive() {
            do {
                try await inject(.screen(application: captured.application, text: captured.text))
                injected = true
            } catch {
                redactedLog("screen inject failed: \(error)")
            }
        }
        if ask, injected {
            await answerNow()
        }
        let sessionID = await sessions?.activeSessionID
        let capture = ScreenContextCapture(id: makeID(), captured: captured, asked: ask && injected, injected: injected, sessionID: sessionID)
        if let sessionID, let store {
            let row = SessionScreenContext(id: capture.id, capturedAt: captured.capturedAt, application: captured.application, windowTitle: captured.windowTitle, text: captured.text)
            do {
                try await store.saveScreenContext(row, sessionID: sessionID)
            } catch {
                redactedLog("screen context save failed: \(error)")
            }
        }
        latest = capture
        broadcaster.yield(.captured(capture))
        return .success(capture)
    }

    public func recentText() -> String? {
        guard let latest, now().timeIntervalSince(latest.captured.capturedAt) <= Self.expansionContextMaxAge else { return nil }
        return latest.captured.text
    }
}
