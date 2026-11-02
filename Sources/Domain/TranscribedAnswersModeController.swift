import Foundation

public struct TranscribedAnswerSessionSettings: Sendable, Equatable {
    public let modelID: String
    public let systemInstructions: String
    public let triggerMode: AnswerTriggerMode
    public let maxOutputTokens: Int
    public let reasoningEffort: String?
    public let useServerSideFallback: Bool

    public init(
        modelID: String,
        systemInstructions: String,
        triggerMode: AnswerTriggerMode,
        maxOutputTokens: Int,
        reasoningEffort: String?,
        useServerSideFallback: Bool
    ) {
        self.modelID = modelID
        self.systemInstructions = systemInstructions
        self.triggerMode = triggerMode
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEffort = reasoningEffort
        self.useServerSideFallback = useServerSideFallback
    }
}

public enum TranscribedAnswersError: Error, Sendable, Equatable {
    case stoppedDuringStart
    case recognitionUnavailable(String)
}

public actor TranscribedAnswersModeController: ModeController {
    private let systemAudio: any SystemAudioCapturing
    private let recognizer: any SpeechFragmentRecognizing
    private let generator: any TextAnswerGenerating
    private let readinessDetector: any QuestionReadinessDetecting
    private let answerTrigger: any AnswerTriggering
    private let preferredAudioSource: (any PreferredAudioSourceStoring)?
    private let settingsProvider: @Sendable () -> TranscribedAnswerSessionSettings
    private let telemetry: SessionTelemetry?
    private let questionAnswerLogger: QuestionAnswerLogger?
    private let latencyRecording: (any LatencyRecording)?
    private let segmenterConfiguration: UtteranceSegmenterConfiguration
    private let maxPendingUtterances: Int
    private let manualFlushTimeout: Duration

    private var generation = 0
    private var isRunning = false
    private var settings: TranscribedAnswerSessionSettings?
    private var segmenter: UtteranceSegmenter
    private var context = SessionTranscriptContext()
    private var pendingUtterances: [SpeechUtterance] = []
    private(set) public var droppedUtteranceCount = 0
    private var recognitionInFlight = false
    private var captureTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var triggerTask: Task<Void, Never>?
    private var captureLease: ResourceLease?
    private var contextWindowStartedAt = Date()

    private var activeResponseID: String?
    private var activeTrigger: AnswerTriggerKind?
    private var activeQuestion = ""
    private var activeConsumesThrough: Int?
    private var activeQuestionReadyAt: Date?
    private var activeUsageRecorded = false
    private var responseVisible = false
    private var sentinelBuffer = ""
    private var streamingText = ""
    private var manualRequestPending = false
    private var spendStopRequested = false

    private(set) public var turnPhase: AnswerTurnPhase = .collectingContext

    private let failureStream: AsyncStream<String>
    private let failureContinuation: AsyncStream<String>.Continuation
    private let streamEventStream: AsyncStream<AnswerStreamEvent>
    private let streamEventContinuation: AsyncStream<AnswerStreamEvent>.Continuation

    public init(
        systemAudio: any SystemAudioCapturing,
        recognizer: any SpeechFragmentRecognizing,
        generator: any TextAnswerGenerating,
        readinessDetector: any QuestionReadinessDetecting = HeuristicQuestionReadinessDetector(),
        answerTrigger: any AnswerTriggering,
        preferredAudioSource: (any PreferredAudioSourceStoring)? = nil,
        settingsProvider: @escaping @Sendable () -> TranscribedAnswerSessionSettings,
        telemetry: SessionTelemetry? = nil,
        questionAnswerLogger: QuestionAnswerLogger? = nil,
        latencyRecording: (any LatencyRecording)? = nil,
        segmenterConfiguration: UtteranceSegmenterConfiguration = .default,
        maxPendingUtterances: Int = 6,
        manualFlushTimeout: Duration = .seconds(4)
    ) {
        self.systemAudio = systemAudio
        self.recognizer = recognizer
        self.generator = generator
        self.readinessDetector = readinessDetector
        self.answerTrigger = answerTrigger
        self.preferredAudioSource = preferredAudioSource
        self.settingsProvider = settingsProvider
        self.telemetry = telemetry
        self.questionAnswerLogger = questionAnswerLogger
        self.latencyRecording = latencyRecording
        self.segmenterConfiguration = segmenterConfiguration
        self.maxPendingUtterances = max(1, maxPendingUtterances)
        self.manualFlushTimeout = manualFlushTimeout
        self.segmenter = UtteranceSegmenter(configuration: segmenterConfiguration)
        (failureStream, failureContinuation) = AsyncStream<String>.makeStream()
        (streamEventStream, streamEventContinuation) = AsyncStream<AnswerStreamEvent>.makeStream()
    }

    nonisolated public func failures() -> AsyncStream<String> {
        failureStream
    }

    nonisolated public func streamEvents() -> AsyncStream<AnswerStreamEvent> {
        streamEventStream
    }

    public var pendingUtteranceCount: Int {
        pendingUtterances.count
    }

    public var accumulatedTranscript: String {
        context.text
    }

    public var isActive: Bool {
        isRunning
    }

    public var hasPendingSpeech: Bool {
        segmenter.hasPendingSpeech
    }

    public func start() async throws {
        generation += 1
        let startGeneration = generation
        resetTurnState()
        context.clearAll()
        pendingUtterances.removeAll()
        droppedUtteranceCount = 0
        segmenter = UtteranceSegmenter(configuration: segmenterConfiguration)
        spendStopRequested = false
        contextWindowStartedAt = Date()
        let settings = settingsProvider()
        self.settings = settings
        streamEventContinuation.yield(.collectingContext)

        await telemetry?.setStatus(.loadingRecognitionModel)
        do {
            try await recognizer.prepare()
        } catch {
            let reason = "\(type(of: error))"
            await telemetry?.recordError(.recognitionUnavailable(reason))
            await telemetry?.setStatus(.providerError(.recognitionUnavailable(reason)))
            throw TranscribedAnswersError.recognitionUnavailable(reason)
        }
        guard startGeneration == generation else { throw TranscribedAnswersError.stoppedDuringStart }

        let targetApplicationBundleID = await preferredAudioSource?.preferredApplicationBundleID()
        let frames = try await systemAudio.start(targetApplicationBundleID: targetApplicationBundleID)
        let systemAudio = self.systemAudio
        captureLease = ResourceLease(name: "systemAudio") { await systemAudio.stop() }
        guard startGeneration == generation else {
            await captureLease?.release()
            captureLease = nil
            throw TranscribedAnswersError.stoppedDuringStart
        }

        isRunning = true
        captureTask = Task { [weak self] in
            for await frame in frames {
                if Task.isCancelled { return }
                await self?.ingest(frame)
            }
            if !Task.isCancelled {
                await self?.captureEnded()
            }
        }
        startTriggerListenerIfNeeded()
        await telemetry?.setStatus(idleStatus)
    }

    public func stop() async {
        isRunning = false
        generation += 1
        captureTask?.cancel(); captureTask = nil
        recognitionTask?.cancel(); recognitionTask = nil
        generationTask?.cancel(); generationTask = nil
        recognitionInFlight = false
        if let questionAnswerLogger, let activeResponseID {
            if responseVisible {
                await questionAnswerLogger.recordCancelled(responseID: activeResponseID)
            } else {
                await questionAnswerLogger.discardBeforeValidAnswer(responseID: activeResponseID)
            }
        }
        await captureLease?.release(); captureLease = nil
        segmenter.reset()
        pendingUtterances.removeAll()
        context.clearAll()
        resetTurnState()
        manualRequestPending = false
        await telemetry?.setHeardText(nil)
        await telemetry?.setStatus(.idle)
    }

    public func resetContext() async {
        guard isRunning else { return }
        if activeResponseID != nil {
            generationTask?.cancel(); generationTask = nil
            if let questionAnswerLogger, let activeResponseID {
                await questionAnswerLogger.discardBeforeValidAnswer(responseID: activeResponseID)
            }
        }
        generation += 1
        pendingUtterances.removeAll()
        recognitionTask?.cancel(); recognitionTask = nil
        recognitionInFlight = false
        segmenter.reset()
        context.clearAll()
        resetTurnState()
        contextWindowStartedAt = Date()
        streamEventContinuation.yield(.collectingContext)
        await telemetry?.setHeardText(nil)
        await telemetry?.setStatus(idleStatus)
    }

    private var idleStatus: AnswerPipelineStatus {
        settings?.triggerMode == .manualOnly ? .waitingForManualTrigger : .listening
    }

    private func resetTurnState() {
        activeResponseID = nil
        activeTrigger = nil
        activeQuestion = ""
        activeConsumesThrough = nil
        activeQuestionReadyAt = nil
        activeUsageRecorded = false
        responseVisible = false
        sentinelBuffer = ""
        streamingText = ""
        turnPhase = .collectingContext
    }

    private func ingest(_ frame: PCMAudioFrame) {
        guard isRunning else { return }
        let utterances = segmenter.ingest(frame)
        for utterance in utterances {
            enqueue(utterance)
        }
    }

    private func enqueue(_ utterance: SpeechUtterance) {
        if pendingUtterances.count >= maxPendingUtterances {
            pendingUtterances.removeFirst()
            droppedUtteranceCount += 1
        }
        pendingUtterances.append(utterance)
        ensureRecognitionWorker()
    }

    private func ensureRecognitionWorker() {
        guard recognitionTask == nil, isRunning else { return }
        let workerGeneration = generation
        recognitionTask = Task { [weak self] in
            await self?.recognitionLoop(generation: workerGeneration)
        }
    }

    private func recognitionLoop(generation workerGeneration: Int) async {
        while workerGeneration == generation, isRunning, !pendingUtterances.isEmpty {
            let utterance = pendingUtterances.removeFirst()
            recognitionInFlight = true
            if activeResponseID == nil { await telemetry?.setStatus(.recognizing) }
            let startedAt = Date()
            let text: String
            do {
                text = try await recognizer.recognize(utterance.frames)
            } catch {
                recognitionInFlight = false
                guard workerGeneration == generation else { return }
                await telemetry?.recordError(.recognitionUnavailable("\(type(of: error))"))
                continue
            }
            recognitionInFlight = false
            guard workerGeneration == generation, isRunning, !Task.isCancelled else { return }
            await telemetry?.recordRecognitionLatency(ms: Int(Date().timeIntervalSince(startedAt) * 1000))
            await handleRecognized(text, utterance: utterance)
        }
        if workerGeneration == generation {
            recognitionTask = nil
            if activeResponseID == nil, isRunning { await telemetry?.setStatus(idleStatus) }
        }
    }

    private func handleRecognized(_ text: String, utterance: SpeechUtterance) async {
        guard let fragment = context.append(text, overlapsPrevious: utterance.overlapsPrevious) else { return }
        await telemetry?.setHeardText(String(context.text.suffix(240)))
        guard settings?.triggerMode == .automatic, activeResponseID == nil, !manualRequestPending else { return }
        let ready = readinessDetector.isReadyToAnswer(
            accumulatedTranscript: context.text,
            lastFragment: fragment.text,
            endedByPause: utterance.endReason == .pause
        )
        if ready {
            await beginAnswer(trigger: .automatic)
        }
    }

    private func startTriggerListenerIfNeeded() {
        guard triggerTask == nil else { return }
        triggerTask = Task { [weak self, answerTrigger] in
            for await _ in answerTrigger.events() {
                if Task.isCancelled { break }
                await self?.handleManualTrigger()
            }
        }
    }

    private func handleManualTrigger() async {
        guard isRunning, !manualRequestPending else { return }
        if activeResponseID != nil {
            guard activeTrigger == .automatic, !responseVisible else { return }
            generationTask?.cancel(); generationTask = nil
            if let questionAnswerLogger, let activeResponseID {
                await questionAnswerLogger.discardBeforeValidAnswer(responseID: activeResponseID)
            }
            resetTurnState()
        }
        let triggerGeneration = generation
        manualRequestPending = true
        turnPhase = .manualResponsePending
        streamEventContinuation.yield(.manualResponsePending)
        if let utterance = segmenter.forceClose() {
            enqueue(utterance)
        }
        let deadline = ContinuousClock.now.advanced(by: manualFlushTimeout)
        while (recognitionTask != nil || !pendingUtterances.isEmpty), ContinuousClock.now < deadline, triggerGeneration == generation {
            try? await Task.sleep(for: .milliseconds(40))
        }
        manualRequestPending = false
        guard triggerGeneration == generation, isRunning else { return }
        guard !context.isEmpty else {
            turnPhase = .collectingContext
            streamEventContinuation.yield(.noContext)
            return
        }
        await beginAnswer(trigger: .manual)
    }

    private func beginAnswer(trigger: AnswerTriggerKind) async {
        guard let settings, isRunning, activeResponseID == nil else { return }
        if spendStopRequested {
            failureContinuation.yield(AnswerProviderError.spendLimitReached.diagnosticCode)
            return
        }
        let responseID = UUID().uuidString
        activeResponseID = responseID
        activeTrigger = trigger
        activeQuestion = context.text
        activeConsumesThrough = context.lastSequence
        activeQuestionReadyAt = Date()
        activeUsageRecorded = false
        responseVisible = false
        sentinelBuffer = ""
        streamingText = ""
        turnPhase = trigger == .automatic ? .automaticResponsePending : .manualResponsePending

        let request = TextAnswerRequest(
            modelID: settings.modelID,
            systemInstructions: settings.systemInstructions,
            transcript: context.text,
            priorExchanges: context.priorExchanges,
            trigger: trigger,
            maxOutputTokens: settings.maxOutputTokens,
            reasoningEffort: settings.reasoningEffort,
            useServerSideFallback: settings.useServerSideFallback
        )
        await telemetry?.setStatus(.generating)
        let answerGeneration = generation
        let generator = self.generator
        generationTask = Task { [weak self] in
            do {
                for try await event in generator.streamAnswer(request) {
                    if Task.isCancelled { return }
                    await self?.handleGenerationEvent(event, responseID: responseID, generation: answerGeneration)
                }
                if Task.isCancelled { return }
                await self?.finishGeneration(responseID: responseID, generation: answerGeneration, error: nil)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                await self?.finishGeneration(responseID: responseID, generation: answerGeneration, error: error)
            }
        }
    }

    private func handleGenerationEvent(_ event: TextAnswerEvent, responseID: String, generation answerGeneration: Int) async {
        guard answerGeneration == generation, responseID == activeResponseID, isRunning else { return }
        switch event {
        case .started(let servedModel):
            if let servedModel { await telemetry?.setServedModel(servedModel) }
        case .servedByFallback(let model):
            await telemetry?.setServedModel(model)
        case .usage(let usage):
            activeUsageRecorded = true
            if await telemetry?.recordUsage(usage) == true {
                spendStopRequested = true
            }
        case .textDelta(let delta):
            await handleDelta(delta, responseID: responseID)
        case .completed:
            break
        }
    }

    private func handleDelta(_ delta: String, responseID: String) async {
        if responseVisible {
            streamingText += delta
            streamEventContinuation.yield(.streaming(text: streamingText))
            return
        }
        sentinelBuffer += delta
        let sentinel = AnswerInstructionsBuilder.waitForQuestionSentinel
        let candidate = sentinelBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty || (sentinel.hasPrefix(candidate) && candidate.count <= sentinel.count) {
            return
        }
        responseVisible = true
        let withoutSentinel = sentinelBuffer.replacingOccurrences(of: sentinel, with: "")
        streamingText = String(withoutSentinel.drop(while: { $0.isWhitespace }))
        sentinelBuffer = ""
        turnPhase = .streaming
        if let readyAt = activeQuestionReadyAt {
            let elapsed = Int(Date().timeIntervalSince(readyAt) * 1000)
            if activeTrigger == .manual {
                await latencyRecording?.record(.manualTriggerToFirstDeltaMs(elapsed))
            } else {
                await latencyRecording?.record(.speechEndToFirstDeltaMs(elapsed))
            }
        }
        streamEventContinuation.yield(.streaming(text: streamingText))
        if let questionAnswerLogger {
            let sourceAppBundleID = await preferredAudioSource?.preferredApplicationBundleID()
            await questionAnswerLogger.beginTextDraft(
                responseID: responseID,
                triggerKind: activeTrigger ?? .automatic,
                sourceAppBundleID: sourceAppBundleID,
                contextWindowStartedAt: contextWindowStartedAt,
                questionText: activeQuestion,
                modelID: settings?.modelID
            )
        }
    }

    private func finishGeneration(responseID: String, generation answerGeneration: Int, error: Error?) async {
        guard answerGeneration == generation, responseID == activeResponseID else { return }
        generationTask = nil
        if let error {
            let providerError = (error as? AnswerProviderError) ?? .unknown("\(type(of: error))")
            await telemetry?.recordError(providerError)
            if responseVisible {
                await questionAnswerLogger?.recordCancelled(responseID: responseID)
            } else {
                await questionAnswerLogger?.discardBeforeValidAnswer(responseID: responseID)
            }
            if responseVisible || activeTrigger == .manual {
                streamEventContinuation.yield(.cancelled)
            }
            resetTurnState()
            await telemetry?.setStatus(.providerError(providerError))
            if providerError.endsSession {
                failureContinuation.yield(providerError.diagnosticCode)
            }
            return
        }

        if !activeUsageRecorded {
            await telemetry?.recordResponseWithoutUsage()
        }

        if responseVisible, !streamingText.isEmpty {
            let finalText = streamingText
            streamEventContinuation.yield(.completed(finalText: finalText))
            let responseTotalMs = activeQuestionReadyAt.map { Int(Date().timeIntervalSince($0) * 1000) }
            await questionAnswerLogger?.recordCompleted(responseID: responseID, finalText: finalText, responseTotalMs: responseTotalMs)
            context.recordExchange(question: activeQuestion, answer: finalText)
            if let consumed = activeConsumesThrough {
                context.consumeThrough(sequence: consumed)
            }
            contextWindowStartedAt = Date()
            resetTurnState()
            turnPhase = .completed
            await telemetry?.setHeardText(context.isEmpty ? nil : String(context.text.suffix(240)))
        } else {
            let wasManual = activeTrigger == .manual
            await questionAnswerLogger?.discardBeforeValidAnswer(responseID: responseID)
            resetTurnState()
            if wasManual {
                streamEventContinuation.yield(.noContext)
            }
        }
        await telemetry?.setStatus(idleStatus)
        if spendStopRequested {
            failureContinuation.yield(AnswerProviderError.spendLimitReached.diagnosticCode)
        }
    }

    private func captureEnded() {
        guard isRunning else { return }
        failureContinuation.yield("system_audio_capture_ended")
    }
}
