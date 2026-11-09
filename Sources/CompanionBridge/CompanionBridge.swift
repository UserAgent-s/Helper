import CompanionProtocol
import CompanionServer
import Domain
import Foundation

public struct CompanionDomainFeeds: Sendable {
    public var modeStates: AsyncStream<ModeState>
    public var answers: AsyncStream<AnswerStreamUpdate>
    public var transcripts: AsyncStream<TranscriptEvent>
    public var levels: AsyncStream<AudioLevel>
    public var notices: AsyncStream<CaptureNotice>

    public init(
        modeStates: AsyncStream<ModeState>,
        answers: AsyncStream<AnswerStreamUpdate>,
        transcripts: AsyncStream<TranscriptEvent>,
        levels: AsyncStream<AudioLevel>,
        notices: AsyncStream<CaptureNotice>
    ) {
        self.modeStates = modeStates
        self.answers = answers
        self.transcripts = transcripts
        self.levels = levels
        self.notices = notices
    }
}

public protocol CompanionDomainControlling: Sendable {
    func currentMode() async -> AppMode
    func requestMode(_ mode: AppMode) async -> ModeTransitionResult
    func isAnswerInFlight() async -> Bool
    func resetContext() async
    func answerNow() async
}

public actor CompanionBridge: CompanionHubDelegate {
    public static let transcriptLimit = 40
    public static let noticeLimit = 10
    public static let levelInterval: Duration = .milliseconds(250)
    public static let baseCapabilities = ["answer_now", "set_mode", "reset_context"]
    public static let sessionCapabilities = ["session.start", "session.stop", "session.resume", "star_last", "mark_moment"]
    public static let exportCapabilities = ["export.request"]
    public static let historyCapabilities = ["history.list", "history.get"]

    private let control: any CompanionDomainControlling
    private let sessions: (any SessionControlling)?
    private let exporter: (any SessionDocumentExporting)?
    private let historyQueries: (any SessionHistoryQuerying)?
    public nonisolated let capabilities: [String]
    private var session: SessionInfo?
    private var announcedSessionId: String?
    private let now: @Sendable () -> Date
    private let makeAnswerId: @Sendable () -> String
    private let clock = ContinuousClock()

    private var modeInfo = ModeInfo(mode: .passive, phase: .idle)
    private var projector: AnswerStreamProjector?
    private var lastAnswer: AnswerState?
    private var transcript: [TranscriptLine] = []
    private var levels: [WireAudioSource: LevelInfo] = [:]
    private var levelSentAt: [WireAudioSource: ContinuousClock.Instant] = [:]
    private var notices: [NoticeInfo] = []
    private var overlayEnabled = true
    private var publisher: (@Sendable (ServerEvent) async -> Void)?
    private var tasks: [Task<Void, Never>] = []
    private let outgoing: AsyncStream<ServerEvent>
    private let outgoingContinuation: AsyncStream<ServerEvent>.Continuation
    private(set) public var publishedEventCount = 0

    public init(
        control: any CompanionDomainControlling,
        sessions: (any SessionControlling)? = nil,
        exporter: (any SessionDocumentExporting)? = nil,
        history: (any SessionHistoryQuerying)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        makeAnswerId: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.control = control
        self.sessions = sessions
        self.exporter = exporter
        historyQueries = history
        capabilities = Self.baseCapabilities + (sessions == nil ? [] : Self.sessionCapabilities) + (exporter == nil ? [] : Self.exportCapabilities) + (history == nil ? [] : Self.historyCapabilities)
        self.now = now
        self.makeAnswerId = makeAnswerId
        (outgoing, outgoingContinuation) = AsyncStream<ServerEvent>.makeStream()
    }

    public func start(feeds: CompanionDomainFeeds) {
        guard tasks.isEmpty else { return }
        let outgoing = self.outgoing
        tasks = [
            Task { [weak self] in
                for await event in outgoing { await self?.forward(event) }
            },
            Task { [weak self] in
                for await state in feeds.modeStates { await self?.ingest(state) }
            },
            Task { [weak self] in
                for await update in feeds.answers { await self?.ingest(update) }
            },
            Task { [weak self] in
                for await event in feeds.transcripts { await self?.ingest(event) }
            },
            Task { [weak self] in
                for await level in feeds.levels { await self?.ingest(level) }
            },
            Task { [weak self] in
                for await notice in feeds.notices { await self?.ingest(notice) }
            },
        ]
        if let sessions {
            let events = sessions.events(subscriber: "companion")
            tasks.append(Task { [weak self] in
                await self?.seedSession(from: sessions)
                for await event in events { await self?.ingest(event) }
            })
        }
    }

    public func shutdown() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        outgoingContinuation.finish()
        publisher = nil
    }

    public func setPublisher(_ publisher: (@Sendable (ServerEvent) async -> Void)?) {
        self.publisher = publisher
    }

    public func setOverlayEnabled(_ enabled: Bool) async {
        guard enabled != overlayEnabled else { return }
        overlayEnabled = enabled
        outgoingContinuation.yield(.stateSnapshot(await snapshot()))
    }

    public func snapshot() async -> StateSnapshot {
        StateSnapshot(
            mode: modeInfo,
            answer: projector?.state ?? lastAnswer,
            transcript: transcript,
            levels: WireAudioSource.allCases.compactMap { levels[$0] },
            notices: notices,
            session: session,
            overlayEnabled: overlayEnabled,
            capabilities: capabilities
        )
    }

    public func perform(_ action: ClientCommand.Action, deviceId: String) async -> CompanionCommandOutcome {
        switch action {
        case .answerNow:
            guard await control.currentMode() == .answers else { return .rejected(code: "not_in_answers_mode") }
            await control.answerNow()
            return .ok
        case .setMode(let request):
            switch await control.requestMode(CompanionWireMapping.appMode(request.mode)) {
            case .succeeded: return .ok
            case .failedToPassive(let reason): return .rejected(code: "mode_transition_failed", message: reason)
            }
        case .resetContext:
            guard await control.currentMode() == .answers else { return .rejected(code: "not_in_answers_mode") }
            guard await !control.isAnswerInFlight() else { return .rejected(code: "answer_in_progress") }
            await control.resetContext()
            return .ok
        case .sessionStart, .sessionStop, .sessionResume, .starLast, .markMoment:
            guard let sessions else { return .rejected(code: "not_available") }
            return await performSession(action, sessions: sessions)
        case .expand, .captureScreen, .exportRequest, .historyList, .historyGet:
            return .rejected(code: "not_available")
        case .hello, .pair, .ping, .unknown:
            return .rejected(code: "unknown_command")
        }
    }

    public func exportDocument(sessionId: String) async -> CompanionExportOutcome {
        guard let exporter else { return .rejected(code: "not_available") }
        guard let uuid = UUID(uuidString: sessionId) else { return .rejected(code: "unknown_session") }
        do {
            guard let document = try await exporter.exportDocument(sessionID: SessionID(rawValue: uuid)) else {
                return .rejected(code: "unknown_session")
            }
            return .document(CompanionExportDocument(filename: document.filename, markdown: document.markdown))
        } catch {
            return .rejected(code: "export_failed")
        }
    }

    public func history(_ action: ClientCommand.Action) async -> CompanionHistoryOutcome {
        guard let historyQueries else { return .rejected(code: "not_available") }
        do {
            switch action {
            case .historyList(let request):
                let limit = request.limit ?? ClientCommand.HistoryList.defaultLimit
                let query = request.q?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !query.isEmpty {
                    let results = try await historyQueries.search(query: query, limit: limit)
                    return .page(.init(q: query, items: results.map(CompanionHistoryMapping.item)))
                }
                var cursor: SessionCursor?
                if let token = request.cursor {
                    guard let parsed = SessionCursor(token: token) else { return .rejected(code: "invalid_cursor") }
                    cursor = parsed
                }
                let page = try await historyQueries.list(limit: limit, after: cursor)
                return .page(.init(cursor: request.cursor, items: page.headers.map(CompanionHistoryMapping.item), nextCursor: page.nextCursor?.token))
            case .historyGet(let request):
                guard let uuid = UUID(uuidString: request.sessionId) else { return .rejected(code: "unknown_session") }
                guard let detail = try await historyQueries.detail(sessionID: SessionID(rawValue: uuid)) else { return .rejected(code: "unknown_session") }
                return .session(CompanionHistoryMapping.fitted(CompanionHistoryMapping.session(detail)))
            default:
                return .rejected(code: "unknown_command")
            }
        } catch {
            return .rejected(code: "history_failed")
        }
    }

    private func performSession(_ action: ClientCommand.Action, sessions: any SessionControlling) async -> CompanionCommandOutcome {
        switch action {
        case .sessionStart:
            if case .active = await sessions.currentState { return .ok }
            do {
                try await sessions.start()
                return .ok
            } catch {
                return .rejected(code: "session_start_failed")
            }
        case .sessionStop:
            guard case .active = await sessions.currentState else { return .ok }
            await sessions.stop()
            return .ok
        case .sessionResume(let request):
            guard let uuid = UUID(uuidString: request.sessionId) else { return .rejected(code: "unknown_session") }
            do {
                try await sessions.resume(sessionID: SessionID(rawValue: uuid))
                return .ok
            } catch SessionCoordinatorError.unknownSession {
                return .rejected(code: "unknown_session")
            } catch {
                return .rejected(code: "session_start_failed")
            }
        case .starLast:
            switch (try? await sessions.toggleStarLastAnswer()) ?? .noCompletedAnswer {
            case .starred, .unstarred: return .ok
            case .noCompletedAnswer: return .rejected(code: "no_completed_answer")
            case .noActiveSession: return .rejected(code: "no_active_session")
            }
        case .markMoment(let request):
            do {
                guard try await sessions.markMoment(note: request.note) != nil else { return .rejected(code: "no_active_session") }
                return .ok
            } catch {
                return .rejected(code: "bookmark_failed")
            }
        default:
            return .rejected(code: "unknown_command")
        }
    }

    private func seedSession(from sessions: any SessionControlling) async {
        guard session == nil, case .active(let id, let startedAt, _) = await sessions.currentState else { return }
        session = SessionInfo(sessionId: CompanionWireMapping.sessionId(id), startedAt: CompanionWireMapping.milliseconds(startedAt))
    }

    func ingest(_ event: SessionEvent) async {
        switch event {
        case .started(let id, let resumed):
            let wireId = CompanionWireMapping.sessionId(id)
            guard announcedSessionId != wireId else { return }
            announcedSessionId = wireId
            var startedAt = now()
            if case .active(id, let at, _) = await sessions?.currentState { startedAt = at }
            let info = SessionInfo(sessionId: wireId, startedAt: CompanionWireMapping.milliseconds(startedAt), resumed: resumed)
            session = info
            emit(.sessionStarted(info))
        case .stopped(let id, let reason):
            let wireId = CompanionWireMapping.sessionId(id)
            if session?.sessionId == wireId { session = nil }
            if announcedSessionId == wireId { announcedSessionId = nil }
            emit(.sessionStopped(.init(sessionId: wireId, endedAt: CompanionWireMapping.milliseconds(now()), reason: CompanionWireMapping.stopReason(reason))))
        case .discarded:
            break
        case .bookmarkAdded(let bookmark):
            emit(.bookmarkAdded(CompanionWireMapping.bookmark(bookmark)))
        case .bookmarkRemoved(let id, let sessionID):
            emit(.bookmarkRemoved(.init(bookmarkId: id, sessionId: CompanionWireMapping.sessionId(sessionID))))
        }
    }

    func ingest(_ state: ModeState) {
        let info = CompanionWireMapping.modeInfo(state)
        if state.mode != .answers {
            closeAnswer(.cancelled)
        }
        guard info != modeInfo else { return }
        modeInfo = info
        emit(.modeChanged(info))
    }

    func ingest(_ update: AnswerStreamUpdate) {
        switch update.event {
        case .streaming(let text):
            let answerId = update.responseID ?? projector?.answerId ?? makeAnswerId()
            if projector?.answerId != answerId {
                closeAnswer(.cancelled)
                let trigger = CompanionWireMapping.trigger(update.trigger)
                projector = AnswerStreamProjector(answerId: answerId, trigger: trigger)
                emit(.answerStarted(.init(answerId: answerId, trigger: trigger, startedAt: CompanionWireMapping.milliseconds(now()))))
            }
            if let event = projector?.update(accumulated: text) {
                emit(event)
            }
        case .completed(let finalText):
            guard projector != nil, update.responseID == nil || update.responseID == projector?.answerId else { return }
            closeAnswer(.completed, finalText: finalText)
        case .cancelled:
            guard projector != nil, update.responseID == nil || update.responseID == projector?.answerId else { return }
            closeAnswer(.cancelled)
        case .collectingContext, .manualResponsePending, .noContext:
            break
        }
    }

    func ingest(_ event: TranscriptEvent) {
        let line = CompanionWireMapping.transcript(event)
        if let index = transcript.lastIndex(where: { $0.itemId == line.itemId && $0.speaker == line.speaker }) {
            transcript[index] = line
        } else {
            transcript.append(line)
            if transcript.count > Self.transcriptLimit {
                transcript.removeFirst(transcript.count - Self.transcriptLimit)
            }
        }
        emit(.transcriptDelta(line))
    }

    func ingest(_ level: AudioLevel) {
        let info = CompanionWireMapping.level(level)
        levels[info.source] = info
        let instant = clock.now
        if let last = levelSentAt[info.source], instant - last < Self.levelInterval { return }
        levelSentAt[info.source] = instant
        emit(.level(info))
    }

    func ingest(_ notice: CaptureNotice) {
        let info = CompanionWireMapping.notice(notice)
        notices.append(info)
        if notices.count > Self.noticeLimit {
            notices.removeFirst(notices.count - Self.noticeLimit)
        }
        emit(.notice(info))
    }

    private func closeAnswer(_ status: WireAnswerStatus, finalText: String? = nil) {
        guard var current = projector else { return }
        for event in current.finish(status, finalText: finalText) {
            emit(event)
        }
        lastAnswer = current.state
        projector = nil
    }

    private func emit(_ event: ServerEvent) {
        outgoingContinuation.yield(event)
    }

    private func forward(_ event: ServerEvent) async {
        publishedEventCount += 1
        await publisher?(event)
    }
}

public struct LiveCompanionDomain: CompanionDomainControlling {
    private let modeCoordinator: ModeCoordinator
    private let answers: AnswersModeController
    private let trigger: ManualAnswerTrigger

    public init(modeCoordinator: ModeCoordinator, answers: AnswersModeController, trigger: ManualAnswerTrigger) {
        self.modeCoordinator = modeCoordinator
        self.answers = answers
        self.trigger = trigger
    }

    public func currentMode() async -> AppMode {
        await modeCoordinator.currentMode
    }

    public func requestMode(_ mode: AppMode) async -> ModeTransitionResult {
        await modeCoordinator.requestTransition(to: mode, reason: "companion")
    }

    public func isAnswerInFlight() async -> Bool {
        await answers.isAnswerInFlight
    }

    public func resetContext() async {
        await answers.resetContext()
    }

    public func answerNow() async {
        await trigger.fire()
    }

    public static func feeds(modeCoordinator: ModeCoordinator, answers: AnswersModeController, captureHub: CaptureHub) -> CompanionDomainFeeds {
        CompanionDomainFeeds(
            modeStates: modeCoordinator.stateUpdates(subscriber: "companion"),
            answers: answers.answerUpdates(subscriber: "companion"),
            transcripts: answers.transcriptEvents(subscriber: "companion"),
            levels: captureHub.levels.subscribe("companion", policy: .bufferingNewest(8)),
            notices: captureHub.notices.subscribe("companion")
        )
    }
}

public actor CompanionService {
    private let pairing: PairingStore
    private let bridge: CompanionBridge
    private let transport: any CompanionTransport
    private(set) public var configuration: CompanionServerConfiguration
    private let serverVersion: String
    private let addresses: @Sendable () -> [String]
    private let networkMonitor: any CompanionNetworkMonitoring
    private var hub: CompanionHub?
    private(set) public var port: UInt16?

    public init(
        pairing: PairingStore,
        bridge: CompanionBridge,
        transport: any CompanionTransport = FlyingFoxCompanionTransport(),
        configuration: CompanionServerConfiguration = CompanionServerConfiguration(),
        serverVersion: String,
        addresses: @escaping @Sendable () -> [String] = LocalInterfaceAddresses.current,
        networkMonitor: any CompanionNetworkMonitoring = CompanionNetworkMonitor()
    ) {
        self.pairing = pairing
        self.bridge = bridge
        self.transport = transport
        self.configuration = configuration
        self.serverVersion = serverVersion
        self.addresses = addresses
        self.networkMonitor = networkMonitor
    }

    public func panelURLs() -> [String] {
        guard let port else { return [] }
        return CompanionPanelURL.urls(addresses: addresses(), port: port)
    }

    public nonisolated func panelURLUpdates() -> AsyncStream<[String]> {
        let changes = networkMonitor.addressChanges()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { [weak self] in
                for await _ in changes {
                    guard let self else { break }
                    continuation.yield(await self.panelURLs())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public var isRunning: Bool {
        port != nil
    }

    public var pairingStore: PairingStore {
        pairing
    }

    @discardableResult
    public func start() async throws -> UInt16 {
        if let port { return port }
        let hub = CompanionHub(pairing: pairing, delegate: bridge, serverVersion: serverVersion)
        await bridge.setPublisher { event in await hub.publish(event) }
        do {
            let bound = try await transport.start(configuration: configuration, hub: hub)
            self.hub = hub
            port = bound
            return bound
        } catch {
            await bridge.setPublisher(nil)
            throw error
        }
    }

    @discardableResult
    public func update(configuration newValue: CompanionServerConfiguration) async throws -> UInt16? {
        guard newValue != configuration else { return port }
        configuration = newValue
        guard port != nil else { return nil }
        await stop()
        return try await start()
    }

    public func stop() async {
        await bridge.setPublisher(nil)
        await transport.stop()
        hub = nil
        port = nil
    }

    public func connectedDeviceIds() async -> [String] {
        await hub?.authenticatedDeviceIds ?? []
    }
}
