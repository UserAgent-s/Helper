import Foundation

public enum HintTextStatus: Sendable, Equatable {
    case streaming
    case completed
    case failed(String)
}

public struct HintExpansion: Sendable, Equatable {
    public var text: String
    public var status: HintTextStatus

    public init(text: String, status: HintTextStatus) {
        self.text = text
        self.status = status
    }
}

public struct Hint: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public var question: String?
    public var text: String
    public var status: HintTextStatus
    public var expansion: HintExpansion?
    public var pairID: UUID?
    public var fromPreviousSession: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        question: String? = nil,
        text: String,
        status: HintTextStatus,
        expansion: HintExpansion? = nil,
        pairID: UUID? = nil,
        fromPreviousSession: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.question = question
        self.text = text
        self.status = status
        self.expansion = expansion
        self.pairID = pairID
        self.fromPreviousSession = fromPreviousSession
    }
}

public enum HintSessionPhase: String, Sendable, Equatable {
    case inactive
    case starting
    case collectingContext
    case manualResponsePending
    case streaming
    case completed
}

public struct HintSessionState: Sendable, Equatable {
    public var mode: AppMode
    public var phase: HintSessionPhase
    public var provider: AnswerProvider?
    public var modelID: String?
    public var expertAreas: [String]
    public var errorDescription: String?

    public init(
        mode: AppMode = .passive,
        phase: HintSessionPhase = .inactive,
        provider: AnswerProvider? = nil,
        modelID: String? = nil,
        expertAreas: [String] = [],
        errorDescription: String? = nil
    ) {
        self.mode = mode
        self.phase = phase
        self.provider = provider
        self.modelID = modelID
        self.expertAreas = expertAreas
        self.errorDescription = errorDescription
    }
}

public enum HintNotice: String, Sendable, Equatable {
    case noContext
    case expansionUnavailable
}

public enum HintFeedEvent: Sendable, Equatable {
    case snapshot(hints: [Hint], session: HintSessionState)
    case hintStarted(Hint)
    case hintUpdated(Hint)
    case hintCompleted(Hint)
    case expansionUpdated(hintID: UUID, HintExpansion)
    case sessionChanged(HintSessionState)
    case notice(HintNotice)
}

public struct HintExpansionRequest: Sendable, Equatable {
    public let hintID: UUID
    public let question: String?
    public let answer: String

    public init(hintID: UUID, question: String?, answer: String) {
        self.hintID = hintID
        self.question = question
        self.answer = answer
    }
}

public protocol HintExpanding: Sendable {
    func expand(_ request: HintExpansionRequest) -> AsyncThrowingStream<String, Error>
}

public actor HintFeed {
    private let answers: any AnswerSessionControlling
    private let expander: (any HintExpanding)?
    private let repository: (any QuestionAnswerRepository)?
    private let configurationProvider: @Sendable () async -> AnswerSessionConfiguration?
    private let maxHints: Int
    private let broadcaster = EventBroadcaster<HintFeedEvent>()

    private var hints: [Hint] = []
    private var pairs: [UUID: QuestionAnswerPair] = [:]
    private var session = HintSessionState()
    private var currentHintID: UUID?
    private var expansionTasks: [UUID: Task<Void, Never>] = [:]
    private var listeners: [Task<Void, Never>] = []
    private var started = false

    public init(
        answers: any AnswerSessionControlling,
        expander: (any HintExpanding)? = nil,
        repository: (any QuestionAnswerRepository)? = nil,
        configurationProvider: @escaping @Sendable () async -> AnswerSessionConfiguration? = { nil },
        maxHints: Int = 50
    ) {
        self.answers = answers
        self.expander = expander
        self.repository = repository
        self.configurationProvider = configurationProvider
        self.maxHints = max(1, maxHints)
    }

    public func start(modeUpdates: AsyncStream<ModeState>? = nil, pairUpdates: AsyncStream<QuestionAnswerPair>? = nil, initialMode: ModeState? = nil) {
        guard !started else { return }
        started = true
        if let initialMode {
            applyMode(initialMode)
        }
        let answerEvents = answers.streamEvents()
        listeners.append(Task { [weak self] in
            for await event in answerEvents {
                await self?.handle(event)
            }
        })
        if let modeUpdates {
            listeners.append(Task { [weak self] in
                for await state in modeUpdates {
                    await self?.handleMode(state)
                }
            })
        }
        if let pairUpdates {
            listeners.append(Task { [weak self] in
                for await pair in pairUpdates {
                    await self?.handle(pair)
                }
            })
        }
    }

    public func stop() {
        for task in listeners { task.cancel() }
        listeners.removeAll()
        for task in expansionTasks.values { task.cancel() }
        expansionTasks.removeAll()
        started = false
    }

    public func loadHistory(limit: Int) async {
        guard let repository, hints.isEmpty else { return }
        let stored = (try? await repository.history(limit: limit)) ?? []
        let restored = stored
            .filter { $0.status == .completed && !$0.answerText.isEmpty }
            .sorted { $0.askedAt < $1.askedAt }
            .map { pair in
                Hint(
                    createdAt: pair.askedAt,
                    question: pair.questionText,
                    text: pair.answerText,
                    status: .completed,
                    expansion: pair.expansionText.map { HintExpansion(text: $0, status: .completed) },
                    pairID: pair.id,
                    fromPreviousSession: true
                )
            }
        for pair in stored { pairs[pair.id] = pair }
        hints = Array(restored.suffix(maxHints))
    }

    nonisolated public func events() -> AsyncStream<HintFeedEvent> {
        let (stream, continuation) = AsyncStream<HintFeedEvent>.makeStream()
        Task { [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
            await self.attach(continuation)
        }
        return stream
    }

    public var currentHints: [Hint] { hints }
    public var currentSession: HintSessionState { session }

    public func hint(id: UUID) -> Hint? {
        hints.first { $0.id == id }
    }

    public func expand(hintID: UUID) async {
        guard let index = hints.firstIndex(where: { $0.id == hintID }) else { return }
        guard let expander else {
            broadcaster.yield(.notice(.expansionUnavailable))
            return
        }
        if let existing = hints[index].expansion, existing.status == .streaming || existing.status == .completed { return }
        guard hints[index].status == .completed else { return }
        var expansion = HintExpansion(text: "", status: .streaming)
        hints[index].expansion = expansion
        broadcaster.yield(.expansionUpdated(hintID: hintID, expansion))
        let request = HintExpansionRequest(hintID: hintID, question: hints[index].question, answer: hints[index].text)
        expansionTasks[hintID] = Task { [weak self] in
            var text = ""
            do {
                for try await delta in expander.expand(request) {
                    if Task.isCancelled { return }
                    text += delta
                    await self?.updateExpansion(hintID: hintID, HintExpansion(text: text, status: .streaming))
                }
                expansion = HintExpansion(text: text, status: text.isEmpty ? .failed("empty") : .completed)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                let reason = (error as? AnswerProviderError)?.diagnosticCode ?? "\(type(of: error))"
                expansion = HintExpansion(text: text, status: .failed(reason))
            }
            await self?.finishExpansion(hintID: hintID, expansion)
        }
    }

    private func attach(_ continuation: AsyncStream<HintFeedEvent>.Continuation) {
        continuation.yield(.snapshot(hints: hints, session: session))
        let relay = broadcaster.subscribe()
        let forwarder = Task {
            for await event in relay {
                continuation.yield(event)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in forwarder.cancel() }
    }

    private func handle(_ event: AnswerStreamEvent) {
        switch event {
        case .collectingContext:
            setPhase(.collectingContext)
        case .manualResponsePending:
            setPhase(.manualResponsePending)
        case .streaming(let text):
            if let id = currentHintID, let index = hints.firstIndex(where: { $0.id == id }), hints[index].status == .streaming {
                hints[index].text = text
                broadcaster.yield(.hintUpdated(hints[index]))
            } else {
                let hint = Hint(text: text, status: .streaming)
                currentHintID = hint.id
                append(hint)
                broadcaster.yield(.hintStarted(hint))
            }
            setPhase(.streaming)
        case .completed(let finalText):
            if let id = currentHintID, let index = hints.firstIndex(where: { $0.id == id }) {
                hints[index].text = finalText
                hints[index].status = .completed
                attachPendingPair(to: index)
                broadcaster.yield(.hintCompleted(hints[index]))
            } else if !finalText.isEmpty {
                var hint = Hint(text: finalText, status: .completed)
                append(hint)
                if let index = hints.firstIndex(where: { $0.id == hint.id }) {
                    attachPendingPair(to: index)
                    hint = hints[index]
                }
                broadcaster.yield(.hintCompleted(hint))
            }
            currentHintID = nil
            setPhase(.completed)
        case .cancelled:
            if let id = currentHintID, let index = hints.firstIndex(where: { $0.id == id }), hints[index].status == .streaming {
                hints[index].status = .failed("cancelled")
                broadcaster.yield(.hintUpdated(hints[index]))
            }
            currentHintID = nil
            setPhase(.collectingContext)
        case .noContext:
            broadcaster.yield(.notice(.noContext))
            setPhase(.collectingContext)
        }
    }

    private func handleMode(_ state: ModeState) async {
        applyMode(state)
        if state.mode == .answers, state.phase == .active {
            let configuration = await configurationProvider()
            session.provider = configuration?.selection.provider
            session.modelID = configuration?.selection.modelID
            session.expertAreas = configuration?.expertAreas ?? []
            broadcaster.yield(.sessionChanged(session))
        }
    }

    private func applyMode(_ state: ModeState) {
        session.mode = state.mode
        session.errorDescription = state.userFacingError.map { String(describing: $0) }
        switch (state.mode, state.phase) {
        case (.answers, .starting):
            session.phase = .starting
        case (.answers, .active):
            if session.phase == .inactive || session.phase == .starting { session.phase = .collectingContext }
        case (.answers, .stopping), (.answers, .idle), (.answers, .failed):
            session.phase = .inactive
        default:
            session.phase = .inactive
            session.provider = nil
            session.modelID = nil
            session.expertAreas = []
            currentHintID = nil
        }
        broadcaster.yield(.sessionChanged(session))
    }

    private func handle(_ pair: QuestionAnswerPair) {
        pairs[pair.id] = pair
        if let index = hints.firstIndex(where: { $0.pairID == pair.id }) {
            let question = pair.questionText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let newQuestion = (question?.isEmpty == false) ? question : nil
            if hints[index].question != newQuestion {
                hints[index].question = newQuestion
                broadcaster.yield(.hintUpdated(hints[index]))
            }
            return
        }
        guard pair.status == .answerStreaming || pair.status == .completed else { return }
        let candidateIndex: Int?
        if pair.status == .answerStreaming {
            candidateIndex = currentHintID.flatMap { id in hints.firstIndex { $0.id == id && $0.pairID == nil } }
        } else {
            candidateIndex = hints.lastIndex { $0.pairID == nil && $0.status == .completed && $0.text == pair.answerText && !$0.fromPreviousSession }
        }
        guard let index = candidateIndex else { return }
        hints[index].pairID = pair.id
        let question = pair.questionText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let question, !question.isEmpty { hints[index].question = question }
        broadcaster.yield(.hintUpdated(hints[index]))
    }

    private func attachPendingPair(to index: Int) {
        guard hints[index].pairID == nil else { return }
        let text = hints[index].text
        guard let pair = pairs.values.filter({ $0.status == .completed && $0.answerText == text }).sorted(by: { $0.askedAt > $1.askedAt }).first,
              !hints.contains(where: { $0.pairID == pair.id })
        else { return }
        hints[index].pairID = pair.id
        if let question = pair.questionText?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
            hints[index].question = question
        }
    }

    private func append(_ hint: Hint) {
        hints.append(hint)
        if hints.count > maxHints {
            hints.removeFirst(hints.count - maxHints)
        }
    }

    private func setPhase(_ phase: HintSessionPhase) {
        guard session.mode == .answers || phase == .collectingContext else { return }
        guard session.phase != phase else { return }
        session.phase = phase
        broadcaster.yield(.sessionChanged(session))
    }

    private func updateExpansion(hintID: UUID, _ expansion: HintExpansion) {
        guard let index = hints.firstIndex(where: { $0.id == hintID }) else { return }
        hints[index].expansion = expansion
        broadcaster.yield(.expansionUpdated(hintID: hintID, expansion))
    }

    private func finishExpansion(hintID: UUID, _ expansion: HintExpansion) async {
        expansionTasks[hintID] = nil
        guard let index = hints.firstIndex(where: { $0.id == hintID }) else { return }
        hints[index].expansion = expansion
        broadcaster.yield(.expansionUpdated(hintID: hintID, expansion))
        guard expansion.status == .completed, let repository, let pairID = hints[index].pairID, var pair = pairs[pairID] else { return }
        pair.expansionText = expansion.text
        pairs[pairID] = pair
        try? await repository.save(pair)
    }
}
