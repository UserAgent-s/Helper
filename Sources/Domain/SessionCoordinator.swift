import Foundation

public actor SessionCoordinator: SessionControlling, SessionContextProviding {
    private let repository: any SessionRepository
    private let modes: any SessionModeDriving
    private let now: @Sendable () -> Date
    private let idleTimeout: TimeInterval
    private let idleCheckInterval: Duration
    private let beforeFinalize: @Sendable () async -> Void

    private var state: SessionState = .idle {
        didSet { if state != oldValue { stateBroadcaster.yield(state) } }
    }
    private var openSpan: SessionSpan?
    private var passiveSince: Date?
    private var observer: Task<Void, Never>?
    private var idleLoop: Task<Void, Never>?
    private var tail: Task<Void, Never>?
    private var syncQueued = false
    private var pendingCreation: Task<AssistantSession?, Never>?

    private let stateBroadcaster = AsyncBroadcaster<SessionState>(replayLatest: true, initial: .idle)
    private let eventBroadcaster = AsyncBroadcaster<SessionEvent>()

    public init(
        repository: any SessionRepository,
        modes: any SessionModeDriving,
        now: @escaping @Sendable () -> Date = { Date() },
        idleTimeout: TimeInterval = 30 * 60,
        idleCheckInterval: Duration = .seconds(60),
        beforeFinalize: @escaping @Sendable () async -> Void = {}
    ) {
        self.repository = repository
        self.modes = modes
        self.now = now
        self.idleTimeout = idleTimeout
        self.idleCheckInterval = idleCheckInterval
        self.beforeFinalize = beforeFinalize
    }

    public var currentState: SessionState { state }

    public var activeSessionID: SessionID? {
        if case .active(let id, _, _) = state { return id }
        return nil
    }

    public func sessionForCapture(mode: SessionSpanMode) async -> SessionID? {
        switch state {
        case .active(let id, _, _):
            return id
        case .finalizing:
            return nil
        case .idle:
            return await createSession(kind: .assistant, mode: mode)
        }
    }

    nonisolated public func stateUpdates(subscriber: String) -> AsyncStream<SessionState> {
        stateBroadcaster.subscribe(subscriber)
    }

    nonisolated public func events(subscriber: String) -> AsyncStream<SessionEvent> {
        eventBroadcaster.subscribe(subscriber)
    }

    public func startObserving() {
        guard observer == nil else { return }
        let updates = modes.modeStates(subscriber: "session-coordinator")
        observer = Task { [weak self] in
            for await _ in updates {
                await self?.modeChanged()
            }
        }
        let interval = idleCheckInterval
        idleLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self?.checkIdle()
            }
        }
    }

    public func stopObserving() {
        observer?.cancel()
        observer = nil
        idleLoop?.cancel()
        idleLoop = nil
    }

    @discardableResult
    public func start() async throws -> SessionID {
        try await serialized { await $0.performStart() }.get()
    }

    public func stop() async {
        await serialized { await $0.performFinish(reason: .user) }
    }

    @discardableResult
    public func resume(sessionID: SessionID) async throws -> SessionID {
        try await serialized { await $0.performResume(sessionID) }.get()
    }

    public func toggleStarLastAnswer() async throws -> StarToggleResult {
        try await serialized { await $0.performToggleStar() }.get()
    }

    public func markMoment(note: String?) async throws -> SessionBookmark? {
        try await serialized { await $0.performMarkMoment(note) }.get()
    }

    public func checkIdle() async {
        await serialized { await $0.performIdleCheck() }
    }

    private func modeChanged() async {
        guard !syncQueued else { return }
        syncQueued = true
        await serialized { await $0.performSync() }
    }

    private func serialized<T: Sendable>(_ body: @escaping @Sendable (SessionCoordinator) async -> T) async -> T {
        let prior = tail
        let task = Task { [self] in
            _ = await prior?.value
            return await body(self)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func performStart() async -> Result<SessionID, any Error> {
        if case .active(let id, _, _) = state {
            _ = await modes.requestTransition(to: .answers)
            await performSync()
            return .success(id)
        }
        do {
            let repository = self.repository
            let at = now()
            let session = try await repository.create(kind: .assistant, mode: .answers, at: at)
            if case .active(let id, _, _) = state {
                _ = try? await repository.deleteIfEmpty(sessionID: session.id)
                _ = await modes.requestTransition(to: .answers)
                await performSync()
                return .success(id)
            }
            activate(session.id, startedAt: session.startedAt, span: session.spans.first)
            eventBroadcaster.yield(.started(session.id, resumed: false))
            _ = await modes.requestTransition(to: .answers)
            await performSync()
            return .success(session.id)
        } catch {
            return .failure(error)
        }
    }

    private func performResume(_ sessionID: SessionID) async -> Result<SessionID, any Error> {
        if case .active(let id, _, _) = state {
            if id == sessionID {
                _ = await modes.requestTransition(to: .answers)
                await performSync()
                return .success(id)
            }
            await performFinish(reason: .user)
        }
        do {
            guard let stored = try await repository.session(id: sessionID) else {
                throw SessionCoordinatorError.unknownSession
            }
            let span = try await repository.resume(sessionID: sessionID, mode: .answers, at: now())
            activate(sessionID, startedAt: stored.startedAt, span: span)
            eventBroadcaster.yield(.started(sessionID, resumed: true))
            _ = await modes.requestTransition(to: .answers)
            await performSync()
            return .success(sessionID)
        } catch {
            return .failure(error)
        }
    }

    private func performFinish(reason: SessionStopReason) async {
        guard case .active(let id, _, _) = state else { return }
        state = .finalizing(sessionID: id)
        openSpan = nil
        passiveSince = nil
        _ = await modes.requestTransition(to: .passive)
        await beforeFinalize()
        try? await repository.finish(sessionID: id, at: now())
        let discarded = (try? await repository.deleteIfEmpty(sessionID: id)) ?? false
        state = .idle
        eventBroadcaster.yield(.stopped(id, reason: reason))
        if discarded { eventBroadcaster.yield(.discarded(id)) }
    }

    private func performToggleStar() async -> Result<StarToggleResult, any Error> {
        guard let sessionID = activeSessionID else { return .success(.noActiveSession) }
        do {
            guard let answerID = try await repository.latestCompletedAnswerID(sessionID: sessionID) else {
                return .success(.noCompletedAnswer)
            }
            let existing = try await repository.bookmarks(sessionID: sessionID).filter { $0.kind == .star && $0.questionAnswerID == answerID }
            if !existing.isEmpty {
                for bookmark in existing {
                    try await repository.removeBookmark(id: bookmark.id)
                    eventBroadcaster.yield(.bookmarkRemoved(id: bookmark.id, sessionID: sessionID))
                }
                return .success(.unstarred(questionAnswerID: answerID))
            }
            let star = SessionBookmark(sessionID: sessionID, kind: .star, questionAnswerID: answerID, markedAt: now())
            try await repository.addBookmark(star)
            eventBroadcaster.yield(.bookmarkAdded(star))
            return .success(.starred(star))
        } catch {
            return .failure(error)
        }
    }

    private func performMarkMoment(_ note: String?) async -> Result<SessionBookmark?, any Error> {
        guard let sessionID = activeSessionID else { return .success(nil) }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let moment = SessionBookmark(sessionID: sessionID, kind: .moment, markedAt: now(), note: trimmed?.isEmpty == false ? trimmed : nil)
        do {
            try await repository.addBookmark(moment)
            eventBroadcaster.yield(.bookmarkAdded(moment))
            return .success(moment)
        } catch {
            return .failure(error)
        }
    }

    private func performIdleCheck() async {
        guard case .active(_, _, nil) = state, let passiveSince else { return }
        guard now().timeIntervalSince(passiveSince) >= idleTimeout else { return }
        await performFinish(reason: .idleTimeout)
    }

    private func performSync() async {
        syncQueued = false
        let mode = await modes.currentModeState
        switch (mode.mode, mode.phase) {
        case (.passive, _):
            await enterPassive()
        case (let appMode, .active):
            guard let spanMode = SessionSpanMode(appMode) else { return }
            await enterActive(spanMode)
        default:
            return
        }
    }

    private func enterActive(_ mode: SessionSpanMode) async {
        switch state {
        case .finalizing:
            return
        case .idle:
            _ = await createSession(kind: .assistant, mode: mode)
        case .active(let id, let startedAt, _):
            if let openSpan, openSpan.mode == mode { return }
            guard let span = try? await repository.resume(sessionID: id, mode: mode, at: now()) else { return }
            activate(id, startedAt: startedAt, span: span)
        }
    }

    private func enterPassive() async {
        guard case .active(let id, let startedAt, _) = state else { return }
        if passiveSince == nil { passiveSince = now() }
        guard let span = openSpan else { return }
        openSpan = nil
        state = .active(sessionID: id, startedAt: startedAt, mode: nil)
        try? await repository.closeSpan(id: span.id, at: now(), reason: .modeChanged)
    }

    private func createSession(kind: SessionKind, mode: SessionSpanMode) async -> SessionID? {
        let task: Task<AssistantSession?, Never>
        let created: Bool
        if let pendingCreation {
            task = pendingCreation
            created = false
        } else {
            let repository = self.repository
            let at = now()
            task = Task { try? await repository.create(kind: kind, mode: mode, at: at) }
            pendingCreation = task
            created = true
        }
        let session = await task.value
        if created { pendingCreation = nil }
        guard let session else { return activeSessionID }
        if case .idle = state {
            activate(session.id, startedAt: session.startedAt, span: session.spans.first)
            eventBroadcaster.yield(.started(session.id, resumed: false))
            return session.id
        }
        if activeSessionID != session.id, created {
            _ = try? await repository.deleteIfEmpty(sessionID: session.id)
        }
        return activeSessionID
    }

    private func activate(_ id: SessionID, startedAt: Date, span: SessionSpan?) {
        openSpan = span
        passiveSince = span == nil ? now() : nil
        state = .active(sessionID: id, startedAt: startedAt, mode: span?.mode)
    }
}

public enum SessionCoordinatorError: Error, Sendable, Equatable {
    case unknownSession
}
