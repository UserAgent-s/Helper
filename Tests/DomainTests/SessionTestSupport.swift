import Foundation
@testable import Domain

actor InMemorySessionRepository: SessionRepository {
    private(set) var sessions: [SessionID: AssistantSession] = [:]
    private(set) var storedBookmarks: [SessionBookmark] = []
    var completedAnswers: [SessionID: [UUID]] = [:]
    var failCreate = false
    private(set) var questionAnswers: [SessionID: [QuestionAnswerPair]] = [:]

    func setQuestionAnswers(_ pairs: [QuestionAnswerPair], for sessionID: SessionID) {
        questionAnswers[sessionID] = pairs
    }

    func setCompletedAnswers(_ answers: [UUID], for sessionID: SessionID) {
        completedAnswers[sessionID] = answers
    }

    func setFailCreate(_ value: Bool) {
        failCreate = value
    }

    func create(kind: SessionKind, mode: SessionSpanMode, at date: Date) async throws -> AssistantSession {
        if failCreate { throw SessionCoordinatorError.unknownSession }
        let id = SessionID()
        let session = AssistantSession(id: id, kind: kind, startedAt: date, status: .recording, lastActivityAt: date, spans: [SessionSpan(sessionID: id, mode: mode, startedAt: date)])
        sessions[id] = session
        return session
    }

    func resume(sessionID: SessionID, mode: SessionSpanMode, at date: Date) async throws -> SessionSpan {
        guard var session = sessions[sessionID] else { throw SessionCoordinatorError.unknownSession }
        if let open = session.openSpan, open.mode == mode, session.status == .recording { return open }
        session.spans = session.spans.map { span in
            var span = span
            if span.isOpen {
                span.endedAt = date
                span.endReason = .modeChanged
            }
            return span
        }
        let span = SessionSpan(sessionID: sessionID, mode: mode, startedAt: date)
        session.spans.append(span)
        session.status = .recording
        session.endedAt = nil
        session.lastActivityAt = date
        sessions[sessionID] = session
        return span
    }

    func closeSpan(id: String, at date: Date, reason: SessionSpanEndReason) async throws {
        for (key, var session) in sessions {
            guard let index = session.spans.firstIndex(where: { $0.id == id && $0.isOpen }) else { continue }
            session.spans[index].endedAt = date
            session.spans[index].endReason = reason
            session.lastActivityAt = date
            sessions[key] = session
        }
    }

    func finish(sessionID: SessionID, at date: Date) async throws {
        guard var session = sessions[sessionID] else { return }
        for index in session.spans.indices where session.spans[index].isOpen {
            session.spans[index].endedAt = date
            session.spans[index].endReason = .stopped
        }
        session.status = .completed
        session.endedAt = date
        session.lastActivityAt = date
        sessions[sessionID] = session
    }

    func session(id: SessionID) async throws -> AssistantSession? {
        sessions[id]
    }

    func headers(limit: Int, after cursor: SessionCursor?) async throws -> SessionPage {
        SessionPage(headers: [], nextCursor: nil)
    }

    func detail(sessionID: SessionID) async throws -> SessionDetail? {
        guard let session = sessions[sessionID] else { return nil }
        return SessionDetail(session: session, utterances: utterances[sessionID] ?? [], questionAnswers: questionAnswers[sessionID] ?? [], bookmarks: storedBookmarks.filter { $0.sessionID == sessionID }, expansions: [], screenContexts: [])
    }

    func addBookmark(_ bookmark: SessionBookmark) async throws {
        storedBookmarks.append(bookmark)
    }

    func bookmarks(sessionID: SessionID) async throws -> [SessionBookmark] {
        storedBookmarks.filter { $0.sessionID == sessionID }
    }

    func latestCompletedAnswerID(sessionID: SessionID) async throws -> UUID? {
        completedAnswers[sessionID]?.last
    }

    func removeBookmark(id: String) async throws {
        storedBookmarks.removeAll { $0.id == id }
    }

    func setTitle(sessionID: SessionID, title: String, source: SessionTitleSource) async throws {
        sessions[sessionID]?.title = title
        sessions[sessionID]?.titleSource = source
    }

    func setPinned(sessionID: SessionID, pinned: Bool) async throws {
        sessions[sessionID]?.pinned = pinned
    }

    func purge(olderThan date: Date, excluding active: SessionID?) async throws -> [SessionID] {
        []
    }

    private(set) var utterances: [SessionID: [SessionUtterance]] = [:]
    private(set) var discardedSessions: [SessionID] = []
    var failAppend = false

    func setFailAppend(_ value: Bool) {
        failAppend = value
    }

    func appendUtterance(_ utterance: SessionUtterance, sessionID: SessionID) async throws {
        if failAppend { throw SessionCoordinatorError.unknownSession }
        guard sessions[sessionID] != nil else { throw SessionCoordinatorError.unknownSession }
        utterances[sessionID, default: []].append(utterance)
        if let at = utterance.capturedAt { sessions[sessionID]?.lastActivityAt = at }
    }

    func deleteIfEmpty(sessionID: SessionID) async throws -> Bool {
        guard let session = sessions[sessionID], !session.pinned else { return false }
        let hasContent = !(utterances[sessionID] ?? []).isEmpty
            || !(completedAnswers[sessionID] ?? []).isEmpty
            || storedBookmarks.contains { $0.sessionID == sessionID }
            || session.spans.contains { $0.mode == .recording }
        guard !hasContent else { return false }
        sessions[sessionID] = nil
        discardedSessions.append(sessionID)
        return true
    }
}

actor FakeSessionModes: SessionModeDriving {
    private let broadcaster = AsyncBroadcaster<ModeState>(replayLatest: true, initial: .initialPassive)
    private(set) var requests: [AppMode] = []
    private(set) var current: AppMode = .passive
    private var failing: Set<AppMode> = []
    private(set) var currentModeState: ModeState = .initialPassive

    private func publish(_ state: ModeState) {
        currentModeState = state
        broadcaster.yield(state)
    }

    func failNext(_ mode: AppMode) {
        failing.insert(mode)
    }

    nonisolated func modeStates(subscriber: String) -> AsyncStream<ModeState> {
        broadcaster.subscribe(subscriber)
    }

    func requestTransition(to mode: AppMode) async -> ModeTransitionResult {
        requests.append(mode)
        guard mode != current else { return .succeeded(mode) }
        if current != .passive {
            publish(ModeState(mode: current, phase: .stopping, startedAt: nil, userFacingError: nil))
        }
        publish(.initialPassive)
        current = .passive
        guard mode != .passive else { return .succeeded(.passive) }
        publish(ModeState(mode: mode, phase: .starting, startedAt: nil, userFacingError: nil))
        if failing.remove(mode) != nil {
            publish(ModeState(mode: .passive, phase: .idle, startedAt: nil, userFacingError: .unknown))
            return .failedToPassive(reason: "injected")
        }
        current = mode
        publish(ModeState(mode: mode, phase: .active, startedAt: Date(), userFacingError: nil))
        return .succeeded(mode)
    }

    func externalSwitch(to mode: AppMode) async {
        _ = await requestTransition(to: mode)
    }

    func runtimeFailure() {
        publish(.initialPassive)
        current = .passive
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_793_000_000)) {
        value = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}
