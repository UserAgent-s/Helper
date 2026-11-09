import Foundation

public actor QuestionAnswerLogger {
    private enum TranscriptOutcome: Equatable {
        case text(String)
        case failed
    }

    private struct Draft {
        var pair: QuestionAnswerPair
        let questionItemIDs: [String]
        var timeoutTask: Task<Void, Never>?
    }

    private let repository: any QuestionAnswerRepository
    nonisolated public let answerModelID: String
    private let questionTranscriptionModelID: @Sendable () -> String?
    private let transcriptTimeout: Duration
    private let transcriptRetention: Int
    private let sessions: (any SessionContextProviding)?

    private var drafts: [String: Draft] = [:]
    private var outcomes: [String: TranscriptOutcome] = [:]
    private var outcomeOrder: [String] = []
    private var writeTail: Task<Void, Never>?

    public init(
        repository: any QuestionAnswerRepository,
        answerModelID: String,
        questionTranscriptionModelID: @escaping @Sendable () -> String? = { nil },
        transcriptTimeout: Duration = .seconds(20),
        transcriptRetention: Int = 256,
        sessions: (any SessionContextProviding)? = nil
    ) {
        self.repository = repository
        self.answerModelID = answerModelID
        self.questionTranscriptionModelID = questionTranscriptionModelID
        self.transcriptTimeout = transcriptTimeout
        self.transcriptRetention = transcriptRetention
        self.sessions = sessions
    }

    public func flush() async {
        await writeTail?.value
    }

    public func beginDraft(
        responseID: String,
        triggerKind: AnswerTriggerKind,
        sourceAppBundleID: String?,
        contextWindowStartedAt: Date,
        questionItemIDs: [String]
    ) async {
        guard drafts[responseID] == nil else { return }
        let sessionID = await sessions?.activeSessionID
        guard drafts[responseID] == nil else { return }

        let now = Date()
        let durationMs = max(0, Int(now.timeIntervalSince(contextWindowStartedAt) * 1000))
        let pair = QuestionAnswerPair(
            askedAt: now,
            sourceAppBundleID: sourceAppBundleID,
            contextWindowStartedAt: contextWindowStartedAt,
            contextWindowDurationMs: durationMs,
            triggerKind: triggerKind,
            answerText: "",
            answerModelID: answerModelID,
            questionTranscriptionModelID: questionTranscriptionModelID(),
            responseID: responseID,
            status: .answerStreaming,
            sessionID: sessionID
        )
        drafts[responseID] = Draft(pair: pair, questionItemIDs: questionItemIDs)
        persist(pair)
        guard !resolveIfReady(responseID: responseID) else { return }

        let timeout = transcriptTimeout
        drafts[responseID]?.timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.resolveOnTimeout(responseID: responseID)
        }
    }

    public func recordTranscript(_ event: TranscriptEvent) {
        guard event.isFinal else { return }
        let trimmed = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        store(trimmed.isEmpty ? .failed : .text(trimmed), for: event.itemID)
    }

    public func recordTranscriptFailed(itemID: String) {
        store(.failed, for: itemID)
    }

    public func recordCompleted(responseID: String, finalText: String, responseTotalMs: Int?) {
        guard var draft = drafts[responseID] else { return }
        draft.pair.answerText = finalText
        draft.pair.responseTotalMs = responseTotalMs
        draft.pair.status = .completed
        drafts[responseID] = draft
        persist(draft.pair)
        pruneIfSettled(responseID)
    }

    public func recordCancelled(responseID: String) {
        guard var draft = drafts[responseID] else { return }
        draft.pair.status = .cancelled
        drafts[responseID] = draft
        persist(draft.pair)
        pruneIfSettled(responseID)
    }

    public func discardBeforeValidAnswer(responseID: String) {
        drafts[responseID]?.timeoutTask?.cancel()
        drafts[responseID] = nil
    }

    private func store(_ outcome: TranscriptOutcome, for itemID: String) {
        if outcomes[itemID] == nil {
            outcomeOrder.append(itemID)
        }
        outcomes[itemID] = outcome
        while outcomeOrder.count > transcriptRetention {
            outcomes[outcomeOrder.removeFirst()] = nil
        }
        let waiting = drafts.filter { $0.value.pair.questionTranscriptionStatus == .pending && $0.value.questionItemIDs.contains(itemID) }
        for responseID in waiting.keys {
            resolveIfReady(responseID: responseID)
        }
    }

    @discardableResult
    private func resolveIfReady(responseID: String) -> Bool {
        guard let draft = drafts[responseID], draft.pair.questionTranscriptionStatus == .pending else { return true }
        guard draft.questionItemIDs.allSatisfy({ outcomes[$0] != nil }) else { return false }
        finalizeQuestion(responseID: responseID)
        return true
    }

    private func resolveOnTimeout(responseID: String) {
        guard drafts[responseID]?.pair.questionTranscriptionStatus == .pending else { return }
        finalizeQuestion(responseID: responseID)
    }

    private func finalizeQuestion(responseID: String) {
        guard var draft = drafts[responseID] else { return }
        draft.timeoutTask?.cancel()
        draft.timeoutTask = nil
        let parts = draft.questionItemIDs.compactMap { id -> String? in
            if case .text(let text) = outcomes[id] { return text }
            return nil
        }
        let text = parts.joined(separator: " ")
        draft.pair.questionText = text.isEmpty ? nil : text
        draft.pair.questionTranscriptionStatus = text.isEmpty ? .failed : .completed
        drafts[responseID] = draft
        persist(draft.pair)
        pruneIfSettled(responseID)
    }

    private func pruneIfSettled(_ responseID: String) {
        guard let draft = drafts[responseID],
              draft.pair.status != .answerStreaming,
              draft.pair.questionTranscriptionStatus != .pending
        else { return }
        drafts[responseID] = nil
    }

    public var pendingDraftCount: Int {
        drafts.count
    }

    private func persist(_ pair: QuestionAnswerPair) {
        let repository = self.repository
        let previous = writeTail
        writeTail = Task {
            await previous?.value
            try? await repository.save(pair)
        }
    }
}
