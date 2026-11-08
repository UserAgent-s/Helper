import Foundation

public actor AnswersModeController: ModeController {
    private let systemAudio: any SystemAudioCapturing
    private let realtime: any RealtimeAnswering
    private let answerTrigger: any AnswerTriggering
    private let preferredAudioSource: (any PreferredAudioSourceStoring)?
    private let instructionsProvider: @Sendable () -> String
    private let answersRingBuffer: AnswersRingBuffer
    private let questionAnswerLogger: QuestionAnswerLogger?
    private let latencyRecording: (any LatencyRecording)?

    private var captureTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var triggerTask: Task<Void, Never>?
    private var didStartPersistentListeners = false
    private var isRunning = false
    private var captureLease: ResourceLease?
    private var realtimeLease: ResourceLease?

    private(set) public var turnPhase: AnswerTurnPhase = .collectingContext
    private(set) public var activeResponseID: String?
    private var activeResponseTrigger: AnswerTriggerKind?
    private var responseStartedAt: Date?
    private var contextWindowStartedAt = Date()
    private var streamingText = ""

    private let failureStream: AsyncStream<String>
    private let failureContinuation: AsyncStream<String>.Continuation

    private let streamEventBroadcaster = AsyncBroadcaster<AnswerStreamEvent>()

    public init(
        systemAudio: any SystemAudioCapturing,
        realtime: any RealtimeAnswering,
        answerTrigger: any AnswerTriggering,
        preferredAudioSource: (any PreferredAudioSourceStoring)? = nil,
        instructionsProvider: @escaping @Sendable () -> String,
        answersRingBuffer: AnswersRingBuffer = AnswersRingBuffer(),
        questionAnswerLogger: QuestionAnswerLogger? = nil,
        latencyRecording: (any LatencyRecording)? = nil
    ) {
        self.systemAudio = systemAudio
        self.realtime = realtime
        self.answerTrigger = answerTrigger
        self.preferredAudioSource = preferredAudioSource
        self.instructionsProvider = instructionsProvider
        self.answersRingBuffer = answersRingBuffer
        self.questionAnswerLogger = questionAnswerLogger
        self.latencyRecording = latencyRecording
        (self.failureStream, self.failureContinuation) = AsyncStream<String>.makeStream()
    }

    private func startPersistentListenersIfNeeded() {
        guard !didStartPersistentListeners else { return }
        didStartPersistentListeners = true

        eventsTask = Task { [weak self, realtime] in
            for await event in realtime.events() {
                if Task.isCancelled { break }
                await self?.handle(event)
            }
        }
        triggerTask = Task { [weak self, answerTrigger] in
            for await _ in answerTrigger.events() {
                if Task.isCancelled { break }
                await self?.handleManualTrigger()
            }
        }
    }

    public func start() async throws {
        turnPhase = .collectingContext
        activeResponseID = nil
        activeResponseTrigger = nil
        responseStartedAt = nil
        streamingText = ""
        contextWindowStartedAt = Date()
        await answersRingBuffer.clear()
        streamEventBroadcaster.yield(.collectingContext)

        try await realtime.start(instructions: instructionsProvider())
        let realtime = self.realtime
        realtimeLease = ResourceLease(name: "realtime") { await realtime.stop() }

        let targetApplicationBundleID = await preferredAudioSource?.preferredApplicationBundleID()
        let frames = try await systemAudio.start(targetApplicationBundleID: targetApplicationBundleID)
        let systemAudio = self.systemAudio
        captureLease = ResourceLease(name: "systemAudio") { await systemAudio.stop() }

        let answersRingBuffer = self.answersRingBuffer
        let latencyRecording = self.latencyRecording
        captureTask = Task { [weak self, realtime] in
            for await frame in frames {
                if Task.isCancelled { break }
                let callbackReceivedAt = Date()
                await answersRingBuffer.append(frame)
                await realtime.appendAudio(frame)
                await latencyRecording?.record(.captureCallbackToSendMs(Int(Date().timeIntervalSince(callbackReceivedAt) * 1000)))
            }
            if !Task.isCancelled {
                await self?.reportCaptureStreamEndedUnexpectedly()
            }
        }

        startPersistentListenersIfNeeded()
        isRunning = true
    }

    public func stop() async {
        isRunning = false
        captureTask?.cancel(); captureTask = nil
        if let questionAnswerLogger, let activeResponseID {
            if turnPhase == .streaming {
                await questionAnswerLogger.recordCancelled(responseID: activeResponseID)
            } else {
                await questionAnswerLogger.discardBeforeValidAnswer(responseID: activeResponseID)
            }
        }
        await captureLease?.release(); captureLease = nil
        await realtimeLease?.release(); realtimeLease = nil
        turnPhase = .collectingContext
        activeResponseID = nil
        activeResponseTrigger = nil
        responseStartedAt = nil
        streamingText = ""
    }

    nonisolated public func failures() -> AsyncStream<String> {
        failureStream
    }

    private func reportCaptureStreamEndedUnexpectedly() {
        guard isRunning else { return }
        failureContinuation.yield("system_audio_capture_ended")
    }

    nonisolated public func streamEvents(subscriber: String = #fileID) -> AsyncStream<AnswerStreamEvent> {
        streamEventBroadcaster.subscribe(subscriber)
    }

    private func handle(_ event: RealtimeAnswerEvent) async {
        guard isRunning else { return }
        switch event {
        case .responseStarted(let id, let trigger):
            guard activeResponseID == nil else { return }
            activeResponseID = id
            activeResponseTrigger = trigger
            responseStartedAt = Date()
            turnPhase = trigger == .automatic ? .automaticResponsePending : .manualResponsePending
        case .textDelta(let id, let text):
            guard id == activeResponseID else { return }
            let isFirstDelta = turnPhase != .streaming
            let firstDeltaObservedAt = Date()
            turnPhase = .streaming
            streamingText += text
            streamEventBroadcaster.yield(.streaming(text: streamingText))
            if isFirstDelta {
                await latencyRecording?.record(.firstDeltaToFirstPaintMs(Int(Date().timeIntervalSince(firstDeltaObservedAt) * 1000)))
            }
            if isFirstDelta, let questionAnswerLogger {
                let snapshot = await answersRingBuffer.snapshot()
                let sourceAppBundleID = await preferredAudioSource?.preferredApplicationBundleID()
                await questionAnswerLogger.beginDraft(
                    responseID: id,
                    triggerKind: activeResponseTrigger ?? .automatic,
                    sourceAppBundleID: sourceAppBundleID,
                    contextWindowStartedAt: contextWindowStartedAt,
                    contextSnapshot: snapshot
                )
            }
        case .waitingForQuestion:
            if turnPhase == .completed {
                turnPhase = .collectingContext
                streamEventBroadcaster.yield(.collectingContext)
            }
        case .completed(let id):
            guard id == activeResponseID else { return }
            turnPhase = .completed
            activeResponseID = nil
            let finalText = streamingText
            streamEventBroadcaster.yield(.completed(finalText: finalText))
            if let questionAnswerLogger {
                let responseTotalMs = responseStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
                await questionAnswerLogger.recordCompleted(responseID: id, finalText: finalText, responseTotalMs: responseTotalMs)
            }
            streamingText = ""
            activeResponseTrigger = nil
            responseStartedAt = nil
            contextWindowStartedAt = Date()
            await answersRingBuffer.clear()
        case .cancelled(let id, _):
            guard id == activeResponseID else { return }
            turnPhase = .collectingContext
            activeResponseID = nil
            streamingText = ""
            streamEventBroadcaster.yield(.cancelled)
            if let questionAnswerLogger {
                await questionAnswerLogger.recordCancelled(responseID: id)
            }
            activeResponseTrigger = nil
            responseStartedAt = nil
        case .failed(let reason):
            failureContinuation.yield(reason)
        }
    }

    private func handleManualTrigger() {
        guard isRunning, activeResponseID == nil,
              turnPhase != .manualResponsePending, turnPhase != .automaticResponsePending, turnPhase != .streaming
        else { return }
        turnPhase = .manualResponsePending
        streamEventBroadcaster.yield(.manualResponsePending)
        Task { [realtime] in
            do {
                try await realtime.forceResponse()
            } catch {
                self.handleManualTriggerRejected()
            }
        }
    }

    private func handleManualTriggerRejected() {
        guard turnPhase == .manualResponsePending, activeResponseID == nil else { return }
        turnPhase = .collectingContext
        streamEventBroadcaster.yield(.noContext)
    }
}
