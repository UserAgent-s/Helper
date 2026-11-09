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
    public static let capabilities = ["answer_now", "set_mode", "reset_context"]

    private let control: any CompanionDomainControlling
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
    private var publisher: (@Sendable (ServerEvent) async -> Void)?
    private var tasks: [Task<Void, Never>] = []
    private let outgoing: AsyncStream<ServerEvent>
    private let outgoingContinuation: AsyncStream<ServerEvent>.Continuation
    private(set) public var publishedEventCount = 0

    public init(
        control: any CompanionDomainControlling,
        now: @escaping @Sendable () -> Date = { Date() },
        makeAnswerId: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.control = control
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

    public func snapshot() async -> StateSnapshot {
        StateSnapshot(
            mode: modeInfo,
            answer: projector?.state ?? lastAnswer,
            transcript: transcript,
            levels: WireAudioSource.allCases.compactMap { levels[$0] },
            notices: notices,
            session: nil,
            overlayEnabled: true,
            capabilities: Self.capabilities
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
        case .expand, .captureScreen, .sessionStart, .sessionStop:
            return .rejected(code: "not_available")
        case .hello, .pair, .ping, .unknown:
            return .rejected(code: "unknown_command")
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
    private let configuration: CompanionServerConfiguration
    private let serverVersion: String
    private var hub: CompanionHub?
    private(set) public var port: UInt16?

    public init(
        pairing: PairingStore,
        bridge: CompanionBridge,
        transport: any CompanionTransport = FlyingFoxCompanionTransport(),
        configuration: CompanionServerConfiguration = CompanionServerConfiguration(),
        serverVersion: String
    ) {
        self.pairing = pairing
        self.bridge = bridge
        self.transport = transport
        self.configuration = configuration
        self.serverVersion = serverVersion
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
