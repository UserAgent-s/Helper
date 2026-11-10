import Foundation
import Testing
@testable import Domain

private actor FakeCapturer: ScreenTextCapturing {
    var result: Result<CapturedScreenText, ScreenCaptureFailure>
    private(set) var kinds: [ScreenCaptureKind] = []
    init(_ result: Result<CapturedScreenText, ScreenCaptureFailure>) { self.result = result }
    func capture(_ kind: ScreenCaptureKind) async -> Result<CapturedScreenText, ScreenCaptureFailure> {
        kinds.append(kind)
        return result
    }
}

private actor Recorder {
    private(set) var injected: [InjectedContext] = []
    private(set) var answers = 0
    private(set) var saved: [(SessionScreenContext, SessionID)] = []
    func inject(_ context: InjectedContext) { injected.append(context) }
    func answer() { answers += 1 }
    func save(_ context: SessionScreenContext, _ id: SessionID) { saved.append((context, id)) }
}

private struct Store: ScreenContextStoring {
    let recorder: Recorder
    func saveScreenContext(_ context: SessionScreenContext, sessionID: SessionID) async throws { await recorder.save(context, sessionID) }
}

private final class Mode: @unchecked Sendable {
    var answers: Bool
    init(_ answers: Bool) { self.answers = answers }
}

@Suite struct ScreenContextTriggerTests {
    private let text = CapturedScreenText(text: "Реализуйте LRU-кеш", source: .ocr, application: "Chrome", bundleID: "com.google.Chrome", windowTitle: "Task", truncated: false, capturedAt: Date(timeIntervalSince1970: 1_000), durationMs: 120)

    private func make(answers: Bool, result: Result<CapturedScreenText, ScreenCaptureFailure>? = nil, session: SessionID? = SessionID(), now: Date = Date(timeIntervalSince1970: 1_010)) -> (ScreenContextTrigger, Recorder, FakeCapturer, Mode) {
        let recorder = Recorder()
        let capturer = FakeCapturer(result ?? .success(text))
        let mode = Mode(answers)
        let trigger = ScreenContextTrigger(
            capturer: capturer,
            isAnswersActive: { mode.answers },
            inject: { await recorder.inject($0) },
            answerNow: { await recorder.answer() },
            sessions: FixedSessionContext(session),
            store: Store(recorder: recorder),
            now: { now },
            makeID: { "scr_1" }
        )
        return (trigger, recorder, capturer, mode)
    }

    @Test func captureInAnswersInjectsWithoutResponseAndSaves() async throws {
        let (trigger, recorder, capturer, _) = make(answers: true)
        let capture = try await trigger.trigger(kind: .window).get()
        #expect(capture.injected)
        #expect(!capture.asked)
        #expect(await recorder.injected == [.screen(application: "Chrome", text: "Реализуйте LRU-кеш")])
        #expect(await recorder.answers == 0)
        #expect(await recorder.saved.count == 1)
        #expect(await recorder.saved.first?.0.text == "Реализуйте LRU-кеш")
        #expect(await capturer.kinds == [.window])
    }

    @Test func askInjectsAndFiresExactlyOneAnswer() async throws {
        let (trigger, recorder, _, _) = make(answers: true)
        let capture = try await trigger.trigger(ask: true).get()
        #expect(capture.asked)
        #expect(await recorder.injected.count == 1)
        #expect(await recorder.answers == 1)
    }

    @Test func outsideAnswersNothingIsInjectedOrAnsweredButCaptureIsKept() async throws {
        let (trigger, recorder, _, _) = make(answers: false)
        let events = trigger.events(subscriber: "t")
        let capture = try await trigger.trigger(ask: true).get()
        #expect(!capture.injected)
        #expect(!capture.asked)
        #expect(await recorder.injected.isEmpty)
        #expect(await recorder.answers == 0)
        #expect(await recorder.saved.count == 1)
        for await event in events {
            #expect(event == .captured(capture))
            break
        }
    }

    @Test func failureEmitsEventAndSavesNothing() async {
        let (trigger, recorder, _, _) = make(answers: true, result: .failure(.permissionDenied(.accessibility)))
        let events = trigger.events(subscriber: "t")
        #expect(await trigger.trigger() == .failure(.permissionDenied(.accessibility)))
        #expect(await recorder.saved.isEmpty)
        #expect(await recorder.injected.isEmpty)
        for await event in events {
            #expect(event == .failed(.permissionDenied(.accessibility)))
            break
        }
    }

    @Test func noSessionMeansNoSave() async throws {
        let (trigger, recorder, _, _) = make(answers: true, session: nil)
        _ = try await trigger.trigger().get()
        #expect(await recorder.saved.isEmpty)
    }

    @Test func recentTextExpiresForExpansionContext() async throws {
        let (fresh, _, _, _) = make(answers: false, now: Date(timeIntervalSince1970: 1_100))
        #expect(await fresh.recentText() == nil)
        _ = try await fresh.trigger().get()
        #expect(await fresh.recentText() == "Реализуйте LRU-кеш")
        let (stale, _, _, _) = make(answers: false, now: Date(timeIntervalSince1970: 1_000 + ScreenContextTrigger.expansionContextMaxAge + 1))
        _ = try await stale.trigger().get()
        #expect(await stale.recentText() == nil)
    }
}
