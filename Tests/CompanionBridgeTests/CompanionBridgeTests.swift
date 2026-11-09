import CompanionProtocol
import Domain
import Foundation
import Testing
@testable import CompanionBridge

@Suite struct CompanionBridgeTests {
    private func makeBridge(control: FakeDomainControl = FakeDomainControl()) async -> (CompanionBridge, ManualFeeds, EventSink) {
        let ids = LockedCounter()
        let bridge = CompanionBridge(control: control, now: { Date(timeIntervalSince1970: 1_000) }, makeAnswerId: { "gen-\(ids.next())" })
        let feeds = ManualFeeds()
        let sink = EventSink()
        await bridge.setPublisher { event in await sink.append(event) }
        await bridge.start(feeds: feeds.feeds)
        return (bridge, feeds, sink)
    }

    private func update(_ id: String?, _ event: AnswerStreamEvent, trigger: AnswerTriggerKind? = .automatic) -> AnswerStreamUpdate {
        AnswerStreamUpdate(responseID: id, trigger: trigger, event: event)
    }

    @Test func markerNeverReachesWire() async throws {
        let (bridge, feeds, sink) = await makeBridge()
        feeds.answers.yield(update("r1", .streaming(text: "Ответ ⟦WAIT_")))
        feeds.answers.yield(update("r1", .streaming(text: "Ответ ⟦WAIT_FOR_QUESTION⟧ дальше")))
        feeds.answers.yield(update("r1", .completed(finalText: "Ответ ⟦WAIT_FOR_QUESTION⟧ дальше")))
        await waitUntil { await sink.types.contains("answer.done") }

        let wire = await sink.texts.joined()
        #expect(!wire.contains("⟦"))
        #expect(!wire.contains("WAIT_FOR_QUESTION"))
        let snapshot = await bridge.snapshot()
        #expect(snapshot.answer?.text.contains("⟦") == false)
        #expect(snapshot.answer?.status == .completed)
    }

    @Test func firstDeltaPublishedBeforeDoneAndOneStartedPerResponse() async throws {
        let (bridge, feeds, sink) = await makeBridge()
        defer { withExtendedLifetime(bridge) {} }
        feeds.answers.yield(update("r1", .streaming(text: "Пер"), trigger: .manual))
        feeds.answers.yield(update("r1", .streaming(text: "Первый"), trigger: .manual))
        await waitUntil { await sink.types.filter { $0 == "answer.delta" }.count == 2 }
        #expect(await !sink.types.contains("answer.done"))

        feeds.answers.yield(update("r1", .completed(finalText: "Первый"), trigger: .manual))
        await waitUntil { await sink.types.contains("answer.done") }
        let events = await sink.events
        #expect(await sink.types == ["answer.started", "answer.delta", "answer.delta", "answer.done"])
        guard case .answerStarted(let started) = events[0] else { Issue.record("no started"); return }
        #expect(started.answerId == "r1")
        #expect(started.trigger == .manual)
        guard case .answerDelta(let second) = events[2] else { Issue.record("no delta"); return }
        #expect(second.offset == 3)
        #expect(second.text == "вый")
    }

    @Test func automaticCatchingUpWithManualYieldsOneStarted() async throws {
        let (bridge, feeds, sink) = await makeBridge()
        defer { withExtendedLifetime(bridge) {} }
        feeds.answers.yield(update(nil, .manualResponsePending, trigger: nil))
        feeds.answers.yield(update("manual-1", .streaming(text: "Ручной"), trigger: .manual))
        feeds.answers.yield(update("manual-1", .streaming(text: "Ручной ответ"), trigger: .manual))
        feeds.answers.yield(update("auto-1", .cancelled))
        feeds.answers.yield(update("manual-1", .completed(finalText: "Ручной ответ"), trigger: .manual))
        await waitUntil { await sink.types.contains("answer.done") }
        let types = await sink.types
        #expect(types.filter { $0 == "answer.started" }.count == 1)
        #expect(types.filter { $0 == "answer.done" }.count == 1)
    }

    @Test func missingResponseIdFallsBackToGeneratedId() async throws {
        let (bridge, feeds, sink) = await makeBridge()
        defer { withExtendedLifetime(bridge) {} }
        feeds.answers.yield(update(nil, .streaming(text: "a")))
        feeds.answers.yield(update(nil, .streaming(text: "ab")))
        feeds.answers.yield(update(nil, .completed(finalText: "ab")))
        await waitUntil { await sink.types.contains("answer.done") }
        let events = await sink.events
        guard case .answerStarted(let started) = events.first, case .answerDone(let done) = events.last else {
            Issue.record("unexpected \(events)")
            return
        }
        #expect(started.answerId == "gen-1")
        #expect(done.answerId == "gen-1")
        #expect(done.length == 2)
    }

    @Test func newResponseCancelsUnfinishedPrevious() async throws {
        let (bridge, feeds, sink) = await makeBridge()
        defer { withExtendedLifetime(bridge) {} }
        feeds.answers.yield(update("a", .streaming(text: "one")))
        feeds.answers.yield(update("b", .streaming(text: "two")))
        await waitUntil { await sink.types.filter { $0 == "answer.started" }.count == 2 }
        let events = await sink.events
        let done = events.compactMap { if case .answerDone(let d) = $0 { d } else { nil } }
        #expect(done.map(\.answerId) == ["a"])
        #expect(done.first?.status == .cancelled)
    }

    @Test func leavingAnswersModeCancelsStreamingAnswer() async throws {
        let (bridge, feeds, sink) = await makeBridge()
        feeds.mode.yield(ModeState(mode: .answers, phase: .active, startedAt: Date(timeIntervalSince1970: 10), userFacingError: nil))
        feeds.answers.yield(update("a", .streaming(text: "text")))
        await waitUntil { await sink.types.contains("answer.delta") }
        feeds.mode.yield(ModeState(mode: .passive, phase: .idle, startedAt: nil, userFacingError: nil))
        await waitUntil { await sink.types.contains("answer.done") }
        let snapshot = await bridge.snapshot()
        #expect(snapshot.mode == ModeInfo(mode: .passive, phase: .idle))
        #expect(snapshot.answer?.status == .cancelled)
        let modes = await sink.events.compactMap { if case .modeChanged(let m) = $0 { m } else { nil } }
        #expect(modes.first == ModeInfo(mode: .answers, phase: .active, startedAt: 10_000))
    }

    @Test func resetRejectedWhileAnswerInFlight() async throws {
        let control = FakeDomainControl()
        let (bridge, _, _) = await makeBridge(control: control)
        await control.set(inFlight: true)
        #expect(await bridge.perform(.resetContext, deviceId: "d") == .rejected(code: "answer_in_progress"))
        #expect(await control.resetCount == 0)
        await control.set(inFlight: false)
        #expect(await bridge.perform(.resetContext, deviceId: "d") == .ok)
        #expect(await control.resetCount == 1)
        await control.set(mode: .recording)
        #expect(await bridge.perform(.resetContext, deviceId: "d") == .rejected(code: "not_in_answers_mode"))
    }

    @Test func commandsMapToDomainOrNotAvailable() async throws {
        let control = FakeDomainControl()
        let (bridge, _, _) = await makeBridge(control: control)
        #expect(await bridge.perform(.answerNow, deviceId: "d") == .ok)
        #expect(await control.answerNowCount == 1)
        #expect(await bridge.perform(.setMode(.init(mode: .recording)), deviceId: "d") == .ok)
        #expect(await control.requestedModes == [.recording])
        await control.set(transitionResult: .failedToPassive(reason: "permission"))
        #expect(await bridge.perform(.setMode(.init(mode: .answers)), deviceId: "d") == .rejected(code: "mode_transition_failed", message: "permission"))
        for action: ClientCommand.Action in [.expand(.init(pointId: nil)), .captureScreen, .sessionStart(.init()), .sessionStop] {
            #expect(await bridge.perform(action, deviceId: "d") == .rejected(code: "not_available"))
        }
        await control.set(mode: .passive)
        #expect(await bridge.perform(.answerNow, deviceId: "d") == .rejected(code: "not_in_answers_mode"))
        #expect(await control.answerNowCount == 1)
    }

    @Test func snapshotCarriesTranscriptLevelsNoticesAndCapabilities() async throws {
        let (bridge, feeds, sink) = await makeBridge()
        feeds.transcripts.yield(TranscriptEvent(speaker: .them, itemID: "i1", text: "Расска", isFinal: false))
        feeds.transcripts.yield(TranscriptEvent(speaker: .them, itemID: "i1", text: "Расскажите", language: "ru", isFinal: true))
        for index in 0..<3 {
            feeds.levels.yield(AudioLevel(kind: .systemAudio, rmsDBFS: Float(-30 - index), peakDBFS: -10, at: Date()))
        }
        feeds.levels.yield(AudioLevel(kind: .microphone, rmsDBFS: -40, peakDBFS: -20, at: Date()))
        for index in 0..<(CompanionBridge.noticeLimit + 2) {
            feeds.notices.yield(.systemCaptureRestarted(reason: "r\(index)"))
        }
        feeds.notices.yield(.outputRouteChanged(.builtInSpeakers))
        await waitUntil { await sink.types.filter { $0 == "notice" }.count == CompanionBridge.noticeLimit + 3 }

        let snapshot = await bridge.snapshot()
        #expect(snapshot.transcript == [TranscriptLine(itemId: "i1", speaker: .them, text: "Расскажите", isFinal: true, language: "ru")])
        #expect(snapshot.levels.map(\.source) == [.system, .me])
        #expect(snapshot.levels.first?.rmsDBFS == -32)
        #expect(snapshot.notices.count == CompanionBridge.noticeLimit)
        #expect(snapshot.notices.last == NoticeInfo(code: "output_route_changed", severity: .warning, args: ["route": "built_in_speakers"]))
        #expect(snapshot.capabilities == CompanionBridge.capabilities)
        #expect(await sink.types.filter { $0 == "level" }.count == 2)
        #expect(await sink.types.filter { $0 == "transcript.delta" }.count == 2)
    }

    @Test func meChannelNoticeAndMeTranscriptMapToWire() {
        #expect(CompanionWireMapping.notice(.meTranscriptionUnavailable(reason: "reconnect_exhausted")) == NoticeInfo(code: "me_channel_unavailable", severity: .warning, args: ["reason": "reconnect_exhausted"]))
        let line = CompanionWireMapping.transcript(TranscriptEvent(speaker: .me, itemID: "me_1", text: "Я бы начал с профилирования", language: "ru", isFinal: true))
        #expect(line.speaker == .me)
        #expect(line.isFinal)
    }

    @Test func transcriptKeepsBoundedTail() async throws {
        let (bridge, feeds, sink) = await makeBridge()
        for index in 0..<(CompanionBridge.transcriptLimit + 5) {
            feeds.transcripts.yield(TranscriptEvent(speaker: .them, itemID: "i\(index)", text: "t", isFinal: true))
        }
        await waitUntil { await sink.types.count == CompanionBridge.transcriptLimit + 5 }
        let snapshot = await bridge.snapshot()
        #expect(snapshot.transcript.count == CompanionBridge.transcriptLimit)
        #expect(snapshot.transcript.first?.itemId == "i5")
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
