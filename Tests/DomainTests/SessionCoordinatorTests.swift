import Foundation
import Testing
@testable import Domain

@Suite struct SessionCoordinatorTests {
    private struct Harness {
        let repository = InMemorySessionRepository()
        let modes = FakeSessionModes()
        let clock = TestClock()
        let coordinator: SessionCoordinator

        init(idleTimeout: TimeInterval = 30 * 60) {
            let clock = clock
            coordinator = SessionCoordinator(repository: repository, modes: modes, now: { clock.now }, idleTimeout: idleTimeout, idleCheckInterval: .seconds(3_600))
        }

        func observe() async {
            await coordinator.startObserving()
        }

        func session(_ id: SessionID) async throws -> AssistantSession {
            try #require(try await repository.session(id: id))
        }
    }

    private func isActive(_ coordinator: SessionCoordinator, mode: SessionSpanMode?) async -> Bool {
        if case .active(_, _, let current) = await coordinator.currentState { return current == mode }
        return false
    }

    @Test func oneClickStartEntersAnswers() async throws {
        let harness = Harness()
        await harness.observe()
        let id = try await harness.coordinator.start()
        #expect(await harness.modes.requests == [.answers])
        #expect(await harness.modes.current == .answers)
        #expect(await harness.coordinator.activeSessionID == id)
        let stored = try await harness.session(id)
        #expect(stored.kind == .assistant)
        #expect(stored.spans.map(\.mode) == [.answers])
        #expect(stored.openSpan != nil)
        #expect(try await harness.coordinator.start() == id)
        #expect(await harness.repository.sessions.count == 1)
    }

    @Test func stopReturnsToPassiveAndFinalizes() async throws {
        let harness = Harness()
        await harness.observe()
        let events = harness.coordinator.events(subscriber: "test")
        let id = try await harness.coordinator.start()
        harness.clock.advance(120)
        await harness.coordinator.stop()

        #expect(await harness.modes.current == .passive)
        #expect(await harness.coordinator.currentState == .idle)
        #expect(await harness.coordinator.activeSessionID == nil)
        let stored = try await harness.session(id)
        #expect(stored.status == .completed)
        #expect(stored.endedAt == harness.clock.now)
        #expect(stored.openSpan == nil)

        var received: [SessionEvent] = []
        for await event in events {
            received.append(event)
            if received.count == 2 { break }
        }
        #expect(received == [.started(id, resumed: false), .stopped(id, reason: .user)])
        await harness.coordinator.stop()
        #expect(await harness.modes.requests == [.answers, .passive])
    }

    @Test func modeSwitchKeepsSameSession() async throws {
        let harness = Harness()
        await harness.observe()
        let id = try await harness.coordinator.start()
        harness.clock.advance(60)
        await harness.modes.externalSwitch(to: .recording)
        await waitUntil { await isActive(harness.coordinator, mode: .recording) }
        harness.clock.advance(60)
        await harness.modes.externalSwitch(to: .answers)
        await waitUntil { await isActive(harness.coordinator, mode: .answers) }

        #expect(await harness.coordinator.activeSessionID == id)
        #expect(await harness.repository.sessions.count == 1)
        let stored = try await harness.session(id)
        #expect(stored.spans.map(\.mode) == [.answers, .recording, .answers])
        #expect(stored.spans.dropLast().allSatisfy { !$0.isOpen })
    }

    @Test func modeFailureKeepsSessionActive() async throws {
        let harness = Harness()
        await harness.observe()
        await harness.modes.failNext(.answers)
        let id = try await harness.coordinator.start()
        await waitUntil { await isActive(harness.coordinator, mode: nil) }
        #expect(await harness.coordinator.activeSessionID == id)
        #expect(try await harness.session(id).openSpan == nil)

        await harness.modes.externalSwitch(to: .answers)
        await waitUntil { await isActive(harness.coordinator, mode: .answers) }
        await harness.modes.runtimeFailure()
        await waitUntil { await isActive(harness.coordinator, mode: nil) }
        #expect(await harness.coordinator.activeSessionID == id)
        #expect(try await harness.session(id).status == .recording)
    }

    @Test func idleAutoStopAfterTimeout() async throws {
        let harness = Harness()
        await harness.observe()
        let events = harness.coordinator.events(subscriber: "test")
        let id = try await harness.coordinator.start()
        await harness.modes.externalSwitch(to: .passive)
        await waitUntil { await isActive(harness.coordinator, mode: nil) }

        harness.clock.advance(29 * 60)
        await harness.coordinator.checkIdle()
        #expect(await harness.coordinator.activeSessionID == id)

        harness.clock.advance(60)
        await harness.coordinator.checkIdle()
        #expect(await harness.coordinator.currentState == .idle)
        #expect(try await harness.session(id).status == .completed)
        var last: SessionEvent?
        for await event in events {
            last = event
            if case .stopped = event { break }
        }
        #expect(last == .stopped(id, reason: .idleTimeout))
    }

    @Test func activeModeNeverAutoStops() async throws {
        let harness = Harness()
        await harness.observe()
        let id = try await harness.coordinator.start()
        harness.clock.advance(5 * 60 * 60)
        await harness.coordinator.checkIdle()
        #expect(await harness.coordinator.activeSessionID == id)
    }

    @Test func resumeAppendsSpan() async throws {
        let harness = Harness()
        await harness.observe()
        let first = try await harness.coordinator.start()
        await harness.coordinator.stop()
        let second = try await harness.coordinator.start()
        #expect(first != second)

        harness.clock.advance(300)
        let resumed = try await harness.coordinator.resume(sessionID: first)
        #expect(resumed == first)
        #expect(await harness.coordinator.activeSessionID == first)
        #expect(try await harness.session(second).status == .completed)
        let stored = try await harness.session(first)
        #expect(stored.status == .recording)
        #expect(stored.spans.count == 2)
        #expect(stored.openSpan?.startedAt == harness.clock.now)
        #expect(await harness.modes.current == .answers)
        await #expect(throws: SessionCoordinatorError.unknownSession) { try await harness.coordinator.resume(sessionID: SessionID()) }
    }

    @Test func autoStartWhenAnswersWithoutSession() async throws {
        let harness = Harness()
        await harness.observe()
        await harness.modes.externalSwitch(to: .recording)
        await waitUntil { await harness.coordinator.activeSessionID != nil }
        let id = try #require(await harness.coordinator.activeSessionID)
        #expect(try await harness.session(id).spans.map(\.mode) == [.recording])

        await harness.modes.externalSwitch(to: .answers)
        await waitUntil { await isActive(harness.coordinator, mode: .answers) }
        #expect(await harness.repository.sessions.count == 1)
        #expect(try await harness.coordinator.start() == id)
    }

    @Test func twoSubscribersBothReceiveState() async throws {
        let harness = Harness()
        let first = harness.coordinator.stateUpdates(subscriber: "web")
        let second = harness.coordinator.stateUpdates(subscriber: "menu")
        await harness.observe()
        let id = try await harness.coordinator.start()

        for stream in [first, second] {
            var seen: [SessionState] = []
            for await state in stream {
                seen.append(state)
                if state.sessionID == id { break }
            }
            #expect(seen.first == .idle)
            #expect(seen.last?.sessionID == id)
        }
    }

    @Test func starLastAnswerTargetsLatestCompleted() async throws {
        let harness = Harness()
        await harness.observe()
        #expect(try await harness.coordinator.toggleStarLastAnswer() == .noActiveSession)
        let id = try await harness.coordinator.start()
        #expect(try await harness.coordinator.toggleStarLastAnswer() == .noCompletedAnswer)

        let older = UUID()
        let latest = UUID()
        await harness.repository.setCompletedAnswers([older, latest], for: id)
        guard case .starred(let star) = try await harness.coordinator.toggleStarLastAnswer() else {
            Issue.record("expected star")
            return
        }
        #expect(star.questionAnswerID == latest)
        #expect(star.kind == .star)
        #expect(try await harness.repository.bookmarks(sessionID: id) == [star])

        #expect(try await harness.coordinator.toggleStarLastAnswer() == .unstarred(questionAnswerID: latest))
        #expect(try await harness.repository.bookmarks(sessionID: id).isEmpty)
    }

    @Test func markMomentStoresTrimmedNote() async throws {
        let harness = Harness()
        await harness.observe()
        #expect(try await harness.coordinator.markMoment(note: "x") == nil)
        let id = try await harness.coordinator.start()
        let moment = try #require(try await harness.coordinator.markMoment(note: "  вернуться к SLA  "))
        #expect(moment.note == "вернуться к SLA")
        #expect(moment.kind == .moment)
        #expect(moment.sessionID == id)
        #expect(try await harness.coordinator.markMoment(note: "   ")?.note == nil)
    }
}
