import Foundation

enum QuestionAnswerLoggerError: Error, Sendable, Equatable {
    case timeout
}

public actor QuestionAnswerLogger {
    private struct Draft {
        var pair: QuestionAnswerPair
        var whisperTask: Task<Void, Never>?
    }

    private let localTranscribing: any LocalTranscribing
    private let repository: any QuestionAnswerRepository
    nonisolated public let answerModelID: String
    private let questionTranscriptionModelID: @Sendable () -> String?
    private let whisperTimeout: Duration

    private var drafts: [String: Draft] = [:]
    private var writeTail: Task<Void, Never>?

    public init(
        localTranscribing: any LocalTranscribing,
        repository: any QuestionAnswerRepository,
        answerModelID: String,
        questionTranscriptionModelID: @escaping @Sendable () -> String? = { nil },
        whisperTimeout: Duration = .seconds(15)
    ) {
        self.localTranscribing = localTranscribing
        self.repository = repository
        self.answerModelID = answerModelID
        self.questionTranscriptionModelID = questionTranscriptionModelID
        self.whisperTimeout = whisperTimeout
    }

    public func flush() async {
        await writeTail?.value
    }

    public func beginDraft(
        responseID: String,
        triggerKind: AnswerTriggerKind,
        sourceAppBundleID: String?,
        contextWindowStartedAt: Date,
        contextSnapshot: [PCMAudioFrame]
    ) {
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
            status: .answerStreaming
        )
        drafts[responseID] = Draft(pair: pair, whisperTask: nil)
        persist(pair)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.transcribeAndAttach(responseID: responseID, frames: contextSnapshot)
        }
        drafts[responseID]?.whisperTask = task
    }

    public func recordCompleted(responseID: String, finalText: String, responseTotalMs: Int?) {
        guard var draft = drafts[responseID] else { return }
        draft.pair.answerText = finalText
        draft.pair.responseTotalMs = responseTotalMs
        draft.pair.status = .completed
        drafts[responseID] = draft
        persist(draft.pair)
    }

    public func recordCancelled(responseID: String) {
        guard var draft = drafts[responseID] else { return }
        draft.whisperTask?.cancel()
        draft.pair.status = .cancelled
        drafts[responseID] = draft
        persist(draft.pair)
    }

    public func discardBeforeValidAnswer(responseID: String) {
        drafts[responseID]?.whisperTask?.cancel()
        drafts[responseID] = nil
    }

    private func transcribeAndAttach(responseID: String, frames: [PCMAudioFrame]) async {
        let result = await Self.transcribeWithTimeout(frames, using: localTranscribing, timeout: whisperTimeout)
        switch result {
        case .success(let segments):
            let text = segments.map(\.text).joined(separator: " ")
            updateQuestionText(responseID: responseID, text: text.isEmpty ? nil : text, status: .completed)
        case .failure:
            updateQuestionText(responseID: responseID, text: nil, status: .failed)
        }
    }

    private func updateQuestionText(responseID: String, text: String?, status: QuestionTranscriptionStatus) {
        guard var draft = drafts[responseID] else { return }
        draft.pair.questionText = text
        draft.pair.questionTranscriptionStatus = status
        drafts[responseID] = draft
        persist(draft.pair)
    }

    private func persist(_ pair: QuestionAnswerPair) {
        let repository = self.repository
        let previous = writeTail
        writeTail = Task {
            await previous?.value
            try? await repository.save(pair)
        }
    }

    private static func transcribeWithTimeout(
        _ frames: [PCMAudioFrame],
        using transcriber: any LocalTranscribing,
        timeout: Duration
    ) async -> Result<[TranscribedSegment], Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<[TranscribedSegment], Error>, Never>) in
            let resumer = QALoggerSingleResume(continuation)
            Task {
                do {
                    let segments = try await transcriber.transcribe(frames)
                    resumer.resume(.success(segments))
                } catch {
                    resumer.resume(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                resumer.resume(.failure(QuestionAnswerLoggerError.timeout))
            }
        }
    }
}

private final class QALoggerSingleResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<T, Never>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let shouldResume = !didResume
        didResume = true
        lock.unlock()
        if shouldResume {
            continuation.resume(returning: value)
        }
    }
}
