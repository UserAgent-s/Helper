import Domain
import Foundation

public struct ClaudeExpansionSettings: Sendable, Equatable {
    public var defaultModel: ExpansionModelChoice
    public var effort: ClaudeEffort
    public var maxTokens: Int
    public var prewarmOnSessionStart: Bool

    public init(defaultModel: ExpansionModelChoice = .sonnet, effort: ClaudeEffort = .low, maxTokens: Int = 4_096, prewarmOnSessionStart: Bool = true) {
        self.defaultModel = defaultModel
        self.effort = effort
        self.maxTokens = maxTokens
        self.prewarmOnSessionStart = prewarmOnSessionStart
    }
}

public actor ClaudeExpansionClient: ExpansionRequesting {
    struct Conversation {
        let model: ClaudeModel
        let system: [ClaudeSystemBlock]
        let messages: [ClaudeMessage]
        let sessionID: SessionID?
        let questionAnswerID: UUID?
        let format: ExpansionFormat
        let language: ExpansionLanguage
    }

    public static let maxConcurrent = 2

    private let client: ClaudeMessagesClient
    private let hasKey: @Sendable () -> Bool
    private let profile: @Sendable (SessionID?) async -> ProfileSnapshot?
    private let activeSession: @Sendable () async -> SessionID?
    private let store: (any DeepExpansionStoring)?
    private let settings: @Sendable () -> ClaudeExpansionSettings
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String
    private let redactedLog: @Sendable (String) -> Void
    private let clock = ContinuousClock()

    private var conversations: [String: Conversation] = [:]
    private var running: [String: Task<Void, Never>] = [:]
    private var observer: Task<Void, Never>?
    private(set) var lastRequests: [ClaudeMessagesRequest] = []
    private(set) var prewarmCount = 0

    public init(
        client: ClaudeMessagesClient,
        hasKey: @escaping @Sendable () -> Bool,
        profile: @escaping @Sendable (SessionID?) async -> ProfileSnapshot?,
        activeSession: @escaping @Sendable () async -> SessionID?,
        store: (any DeepExpansionStoring)?,
        settings: @escaping @Sendable () -> ClaudeExpansionSettings = { ClaudeExpansionSettings() },
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        redactedLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.client = client
        self.hasKey = hasKey
        self.profile = profile
        self.activeSession = activeSession
        self.store = store
        self.settings = settings
        self.now = now
        self.makeID = makeID
        self.redactedLog = redactedLog
    }

    public func isAvailable() -> Bool {
        hasKey()
    }

    public func expand(_ request: ExpansionRequest) async throws -> AsyncStream<ExpansionEvent> {
        guard hasKey() else { throw ExpansionRejection.unavailable }
        guard running.count < Self.maxConcurrent else { throw ExpansionRejection.busy }
        if case .freeText(let text) = request.source, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ExpansionRejection.emptyQuestion
        }
        let config = settings()
        let sessionID = await activeSession()
        let snapshot = await profile(sessionID)
        let model = Self.model(request.model ?? config.defaultModel)
        var questionAnswerID: UUID?
        if let answerID = request.source.answerID, let store {
            questionAnswerID = try? await store.questionAnswerID(responseID: answerID)
        }
        let conversation = Conversation(
            model: model,
            system: ClaudePromptBuilder.system(profile: snapshot),
            messages: [ClaudePromptBuilder.initialTurn(request)],
            sessionID: sessionID,
            questionAnswerID: questionAnswerID,
            format: request.format,
            language: request.language
        )
        return launch(conversation, parentID: nil, source: request.source, config: config)
    }

    public func followUp(expansionID: String, question: String) async throws -> AsyncStream<ExpansionEvent> {
        guard hasKey() else { throw ExpansionRejection.unavailable }
        guard running.count < Self.maxConcurrent else { throw ExpansionRejection.busy }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExpansionRejection.emptyQuestion }
        guard let parent = conversations[expansionID] else { throw ExpansionRejection.unknownExpansion }
        let conversation = Conversation(
            model: parent.model,
            system: parent.system,
            messages: parent.messages + [ClaudePromptBuilder.followUpTurn(trimmed)],
            sessionID: parent.sessionID,
            questionAnswerID: parent.questionAnswerID,
            format: parent.format,
            language: parent.language
        )
        return launch(conversation, parentID: expansionID, source: .freeText(trimmed), config: settings())
    }

    public func cancel(expansionID: String) {
        running[expansionID]?.cancel()
    }

    public func prewarm(sessionID: SessionID?) async -> ClaudePrewarmResult? {
        let config = settings()
        guard hasKey(), let snapshot = await profile(sessionID), !snapshot.isEmpty else { return nil }
        let request = ClaudeMessagesRequest(
            model: Self.model(config.defaultModel),
            maxTokens: 0,
            stream: false,
            effort: config.effort,
            system: ClaudePromptBuilder.system(profile: snapshot),
            messages: [.user("warmup")]
        )
        prewarmCount += 1
        lastRequests.append(request)
        switch await client.prewarm(request) {
        case .success(let result):
            redactedLog("claude prewarm cache_write=\(result.usage.cacheCreationInputTokens) cache_read=\(result.usage.cacheReadInputTokens)")
            return result
        case .failure(let failure):
            redactedLog("claude prewarm failed: \(failure)")
            return nil
        }
    }

    public func observe(_ events: AsyncStream<SessionEvent>) {
        observer?.cancel()
        observer = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                if case .started(let id, _) = event, self.settings().prewarmOnSessionStart {
                    _ = await self.prewarm(sessionID: id)
                }
            }
        }
    }

    public func stopObserving() {
        observer?.cancel()
        observer = nil
    }

    var conversationIDs: Set<String> { Set(conversations.keys) }

    private func launch(_ conversation: Conversation, parentID: String?, source: ExpansionSource, config: ClaudeExpansionSettings) -> AsyncStream<ExpansionEvent> {
        let id = makeID()
        let request = ClaudeMessagesRequest(
            model: conversation.model,
            maxTokens: config.maxTokens,
            effort: config.effort,
            system: conversation.system,
            messages: conversation.messages
        )
        lastRequests.append(request)
        let requestedAt = now()
        var record = conversation.sessionID.map { sessionID in
            DeepExpansionRecord(
                id: id, sessionID: sessionID, questionAnswerID: conversation.questionAnswerID, parentID: parentID,
                requestedAt: requestedAt, modelID: conversation.model.rawValue, status: "streaming", text: "",
                sourceKind: parentID == nil ? source.kind : "follow_up", pointID: source.pointID, sourceText: source.focusText,
                format: conversation.format.rawValue, language: conversation.language.rawValue
            )
        }
        let (stream, continuation) = AsyncStream<ExpansionEvent>.makeStream()
        let client = self.client
        let store = self.store
        let clock = self.clock
        continuation.yield(.started(expansionID: id, modelID: conversation.model.rawValue, format: conversation.format, language: conversation.language))
        let task = Task { [weak self] in
            if let initial = record { try? await store?.saveExpansion(initial) }
            let startedAt = clock.now
            var text = ""
            var utf16Offset = 0
            var ttftMs: Int?
            var outcome: ExpansionOutcome = .cancelled
            var errorCode: String?
            var usage: ClaudeUsage?
            var servedModel = conversation.model.rawValue
            var stopReason: String?
            for await event in client.stream(request) {
                if Task.isCancelled { break }
                switch event {
                case .started(_, let model, _):
                    if !model.isEmpty { servedModel = model }
                case .textDelta(let chunk):
                    if ttftMs == nil {
                        let elapsed = clock.now - startedAt
                        ttftMs = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                    }
                    continuation.yield(.delta(expansionID: id, offset: utf16Offset, text: chunk))
                    utf16Offset += chunk.utf16.count
                    text += chunk
                case .fallback(_, let to):
                    if let to { servedModel = to }
                case .completed(let completion):
                    outcome = .completed
                    usage = completion.usage
                    stopReason = "end_turn"
                case .truncated(let completion):
                    outcome = .truncated
                    usage = completion.usage
                    stopReason = "max_tokens"
                    errorCode = "max_tokens"
                case .refused(let refusal):
                    outcome = .refused
                    usage = refusal.usage
                    stopReason = "refusal"
                    errorCode = refusal.category.map { "refused_\($0)" } ?? "refused"
                case .failed(let failure):
                    outcome = .failed
                    errorCode = Self.errorCode(failure)
                }
            }
            if Task.isCancelled { outcome = .cancelled }
            if var final = record {
                final.status = outcome.rawValue
                final.text = text
                final.ttftMs = ttftMs
                final.stopReason = stopReason
                if let usage {
                    final.inputTokens = usage.inputTokens
                    final.outputTokens = usage.outputTokens
                    final.cacheReadTokens = usage.cacheReadInputTokens
                    final.cacheWriteTokens = usage.cacheCreationInputTokens
                    final.estimatedCostUSD = ClaudeCostEstimator.estimate(usage, model: ClaudeModel(rawValue: servedModel) ?? conversation.model).total
                }
                record = final
                try? await store?.saveExpansion(final)
            }
            await self?.finish(id: id, conversation: conversation, text: text, outcome: outcome)
            let cost = usage.map { ClaudeCostEstimator.estimate($0, model: ClaudeModel(rawValue: servedModel) ?? conversation.model).total }
            continuation.yield(.stats(expansionID: id, ttftMs: ttftMs, costUSD: cost, modelID: servedModel))
            continuation.yield(.finished(expansionID: id, outcome: outcome, errorCode: errorCode))
            continuation.finish()
        }
        running[id] = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func finish(id: String, conversation: Conversation, text: String, outcome: ExpansionOutcome) {
        running[id] = nil
        guard outcome == .completed || outcome == .truncated, !text.isEmpty else { return }
        conversations[id] = Conversation(
            model: conversation.model,
            system: conversation.system,
            messages: conversation.messages + [.assistant(text)],
            sessionID: conversation.sessionID,
            questionAnswerID: conversation.questionAnswerID,
            format: conversation.format,
            language: conversation.language
        )
    }

    static func model(_ choice: ExpansionModelChoice) -> ClaudeModel {
        switch choice {
        case .sonnet: .sonnet
        case .opus: .opus
        }
    }

    static func errorCode(_ failure: ClaudeFailure) -> String {
        switch failure {
        case .missingAPIKey: "claude_unavailable"
        case .invalidRequest: "invalid_request"
        case .http(let status, _, _) where status == 401 || status == 403: "auth_failed"
        case .http(429, _, _): "rate_limited"
        case .http(let status, _, _) where status >= 500: "overloaded"
        case .http: "claude_error"
        case .api(let type, _) where type == "overloaded_error": "overloaded"
        case .api(let type, _) where type == "rate_limit_error": "rate_limited"
        case .api: "claude_error"
        case .transport: "network"
        case .malformed, .incomplete: "stream_broken"
        }
    }
}
