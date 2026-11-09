import CompanionProtocol
import Domain
import Foundation
import Testing
@testable import CompanionBridge

actor FakeSessionControl: SessionControlling {
    var state: SessionState = .idle
    var starResult: StarToggleResult = .noCompletedAnswer
    var knownSessions: Set<SessionID> = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var resumed: [SessionID] = []
    private(set) var moments: [String?] = []
    let startedAt = Date(timeIntervalSince1970: 500)
    private let eventStream: AsyncStream<SessionEvent>
    let eventContinuation: AsyncStream<SessionEvent>.Continuation

    init(state: SessionState = .idle) {
        self.state = state
        (eventStream, eventContinuation) = AsyncStream<SessionEvent>.makeStream()
    }

    func set(state: SessionState? = nil, starResult: StarToggleResult? = nil, known: SessionID? = nil) {
        if let state { self.state = state }
        if let starResult { self.starResult = starResult }
        if let known { knownSessions.insert(known) }
    }

    var currentState: SessionState { state }

    nonisolated func stateUpdates(subscriber: String) -> AsyncStream<SessionState> {
        AsyncStream { $0.finish() }
    }

    nonisolated func events(subscriber: String) -> AsyncStream<SessionEvent> {
        eventStream
    }

    func start() async throws -> SessionID {
        startCount += 1
        let id = SessionID()
        state = .active(sessionID: id, startedAt: startedAt, mode: .answers)
        return id
    }

    func stop() async {
        stopCount += 1
        state = .idle
    }

    func resume(sessionID: SessionID) async throws -> SessionID {
        guard knownSessions.contains(sessionID) else { throw SessionCoordinatorError.unknownSession }
        resumed.append(sessionID)
        state = .active(sessionID: sessionID, startedAt: startedAt, mode: .answers)
        return sessionID
    }

    func toggleStarLastAnswer() async throws -> StarToggleResult { starResult }

    func markMoment(note: String?) async throws -> SessionBookmark? {
        guard let id = state.sessionID, case .active = state else { return nil }
        moments.append(note)
        return SessionBookmark(sessionID: id, kind: .moment, markedAt: startedAt, note: note)
    }
}

@Suite struct CompanionBridgeSessionTests {
    private func makeBridge(sessions: FakeSessionControl?) async -> (CompanionBridge, EventSink) {
        let bridge = CompanionBridge(control: FakeDomainControl(), sessions: sessions, now: { Date(timeIntervalSince1970: 1_000) })
        let sink = EventSink()
        await bridge.setPublisher { event in await sink.append(event) }
        await bridge.start(feeds: ManualFeeds().feeds)
        return (bridge, sink)
    }

    @Test func sessionCommandsDelegateToSessionControlling() async throws {
        let sessions = FakeSessionControl()
        let (bridge, _) = await makeBridge(sessions: sessions)
        #expect(bridge.capabilities == CompanionBridge.baseCapabilities + CompanionBridge.sessionCapabilities)

        #expect(await bridge.perform(.sessionStop, deviceId: "d") == .ok)
        #expect(await sessions.stopCount == 0)
        #expect(await bridge.perform(.starLast, deviceId: "d") == .rejected(code: "no_completed_answer"))
        #expect(await bridge.perform(.markMoment(.init(note: "x")), deviceId: "d") == .rejected(code: "no_active_session"))

        #expect(await bridge.perform(.sessionStart(.init()), deviceId: "d") == .ok)
        #expect(await bridge.perform(.sessionStart(.init()), deviceId: "d") == .ok)
        #expect(await sessions.startCount == 1)

        let answer = UUID()
        await sessions.set(starResult: .unstarred(questionAnswerID: answer))
        #expect(await bridge.perform(.starLast, deviceId: "d") == .ok)
        await sessions.set(starResult: .noActiveSession)
        #expect(await bridge.perform(.starLast, deviceId: "d") == .rejected(code: "no_active_session"))
        #expect(await bridge.perform(.markMoment(.init(note: "шардирование")), deviceId: "d") == .ok)
        #expect(await sessions.moments == ["шардирование"])

        #expect(await bridge.perform(.sessionStop, deviceId: "d") == .ok)
        #expect(await sessions.stopCount == 1)

        #expect(await bridge.perform(.sessionResume(.init(sessionId: "not-a-uuid")), deviceId: "d") == .rejected(code: "unknown_session"))
        #expect(await bridge.perform(.sessionResume(.init(sessionId: UUID().uuidString)), deviceId: "d") == .rejected(code: "unknown_session"))
        let known = SessionID()
        await sessions.set(known: known)
        #expect(await bridge.perform(.sessionResume(.init(sessionId: known.rawValue.uuidString)), deviceId: "d") == .ok)
        #expect(await sessions.resumed == [known])
    }

    @Test func withoutSessionControlCommandsAreNotAvailable() async throws {
        let (bridge, _) = await makeBridge(sessions: nil)
        #expect(bridge.capabilities == CompanionBridge.baseCapabilities)
        for action: ClientCommand.Action in [.sessionStart(.init()), .sessionStop, .sessionResume(.init(sessionId: "x")), .starLast, .markMoment(.init())] {
            #expect(await bridge.perform(action, deviceId: "d") == .rejected(code: "not_available"))
        }
    }

    @Test func sessionEventsMapToWireAndSnapshot() async throws {
        let sessions = FakeSessionControl()
        let (bridge, sink) = await makeBridge(sessions: sessions)
        let id = try await sessions.start()
        let wireId = id.rawValue.uuidString
        sessions.eventContinuation.yield(.started(id, resumed: false))
        sessions.eventContinuation.yield(.started(id, resumed: false))
        let star = SessionBookmark(id: "bm_1", sessionID: id, kind: .star, questionAnswerID: UUID(uuidString: "8F0C6B2A-3D4E-4F50-9A1B-2C3D4E5F6A7B"), markedAt: Date(timeIntervalSince1970: 700))
        sessions.eventContinuation.yield(.bookmarkAdded(star))
        await waitUntil { await sink.types.contains("bookmark.added") }

        let started = SessionInfo(sessionId: wireId, startedAt: 500_000, resumed: false)
        #expect(await bridge.snapshot().session == started)
        sessions.eventContinuation.yield(.bookmarkRemoved(id: "bm_1", sessionID: id))
        sessions.eventContinuation.yield(.stopped(id, reason: .idleTimeout))
        sessions.eventContinuation.yield(.discarded(id))
        await waitUntil { await sink.types.contains("session.stopped") }
        try? await Task.sleep(for: .milliseconds(30))

        #expect(await sink.events == [
            .sessionStarted(started),
            .bookmarkAdded(BookmarkInfo(bookmarkId: "bm_1", sessionId: wireId, kind: .star, markedAt: 700_000, answerId: "8F0C6B2A-3D4E-4F50-9A1B-2C3D4E5F6A7B")),
            .bookmarkRemoved(.init(bookmarkId: "bm_1", sessionId: wireId)),
            .sessionStopped(.init(sessionId: wireId, endedAt: 1_000_000, reason: .idle)),
        ])
        #expect(await bridge.snapshot().session == nil)
    }

    @Test func activeSessionBeforeBridgeStartAppearsInSnapshot() async throws {
        let id = SessionID()
        let sessions = FakeSessionControl(state: .active(sessionID: id, startedAt: Date(timeIntervalSince1970: 42), mode: nil))
        let (bridge, _) = await makeBridge(sessions: sessions)
        await waitUntil { await bridge.snapshot().session != nil }
        #expect(await bridge.snapshot().session == SessionInfo(sessionId: id.rawValue.uuidString, startedAt: 42_000))
    }
}
