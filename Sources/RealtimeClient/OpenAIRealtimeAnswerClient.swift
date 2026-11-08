import Domain
import Foundation

public enum RealtimeClientError: Error, Sendable, Equatable {
    case notConnected
    case notAuthenticated
    case noContext
}

public enum ForceAnswerStrategy: Sendable, Equatable {
    case systemItem
    case mergedInstructions
}

public actor OpenAIRealtimeAnswerClient: LiveResponder {
    public static let modelID = "gpt-realtime-2.1"
    private static var endpointURL: URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: modelID)]
        return components.url!
    }

    private struct ResponseTextTracker {
        var buffer = ""
        var resolved = false
        var isReal = false
    }

    private let transport: any RealtimeWebSocketTransport
    private let credentialProviding: any RealtimeCredentialProviding
    private let vadSettingsProvider: @Sendable () -> RealtimeVADSettings
    private let latencyRecording: any LatencyRecording
    private let reconnectBaseDelay: Duration
    private let maxReconnectAttempts: Int
    private let redactedLog: @Sendable (String) -> Void

    private let publicStream: AsyncStream<RealtimeAnswerEvent>
    private let publicContinuation: AsyncStream<RealtimeAnswerEvent>.Continuation

    private var instructions = ""
    private let forceAnswerStrategy: ForceAnswerStrategy
    private var sessionActive = false
    private var eventsTask: Task<Void, Never>?
    private var contextWindow = AnswerContextWindow()

    private var trackers: [String: ResponseTextTracker] = [:]
    private var responseTrigger: [String: AnswerTriggerKind] = [:]
    private var inFlightResponseIDs: Set<String> = []
    private var visibleResponseID: String?
    private var awaitingManualResponseCreated = false
    private var speechInProgress = false
    private var pendingManualSend = false

    private var speechStoppedAt: Date?
    private var responseCreatedAt: [String: Date] = [:]
    private var manualTriggerPressedAt: Date?
    private var windowStartedAt: Date?
    private var firstAudioFrameSent = false

    public init(
        transport: any RealtimeWebSocketTransport = URLSessionRealtimeWebSocketTransport(),
        credentialProviding: any RealtimeCredentialProviding,
        vadSettingsProvider: @escaping @Sendable () -> RealtimeVADSettings = { .safeDefault },
        latencyRecording: any LatencyRecording,
        reconnectBaseDelay: Duration = .milliseconds(500),
        maxReconnectAttempts: Int = 3,
        forceAnswerStrategy: ForceAnswerStrategy = .systemItem,
        redactedLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.forceAnswerStrategy = forceAnswerStrategy
        self.transport = transport
        self.credentialProviding = credentialProviding
        self.vadSettingsProvider = vadSettingsProvider
        self.latencyRecording = latencyRecording
        self.reconnectBaseDelay = reconnectBaseDelay
        self.maxReconnectAttempts = maxReconnectAttempts
        self.redactedLog = redactedLog
        (publicStream, publicContinuation) = AsyncStream<RealtimeAnswerEvent>.makeStream()
    }

    nonisolated public func events() -> AsyncStream<RealtimeAnswerEvent> {
        publicStream
    }

    public func start(instructions: String) async throws {
        self.instructions = instructions
        let credential = try await Self.requireCredential(from: credentialProviding)

        resetSessionState()
        try await transport.connect(url: Self.endpointURL, auth: .bearer(credential.apiKey))
        sessionActive = true
        startReceiveLoop()
        try await transport.send(.sessionUpdate(makeSessionConfig()))
        redactedLog("realtime session started (model=\(Self.modelID))")
    }

    public func appendAudio(_ frame: PCMAudioFrame) async {
        guard sessionActive else { return }
        let data = frame.samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let base64 = data.base64EncodedString()
        if !firstAudioFrameSent {
            firstAudioFrameSent = true
            redactedLog("first audio frame sent")
        }
        try? await transport.send(.inputAudioBufferAppend(audioBase64: base64))
    }

    nonisolated public var capabilities: ProviderCapabilities {
        [.serverVAD, .textInjection, .manualResponse, .streamingText]
    }

    public func injectContext(_ text: String) async throws {
        guard sessionActive else { throw RealtimeClientError.notConnected }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let itemID = Self.makeItemID(prefix: "ctx_")
        let evicted = await contextWindow.trackCommittedUserItem(itemID)
        try await transport.send(.conversationItemCreate(ConversationItemPayload(
            id: itemID,
            role: .system,
            text: RealtimeInstructions.injectedContextPrefix + trimmed
        )))
        for id in evicted { try? await transport.send(.conversationItemDelete(itemID: id)) }
    }

    public func forceResponse() async throws {
        guard sessionActive else { throw RealtimeClientError.notConnected }
        let hasCommittedContext = await contextWindow.committedItemCount > 0

        guard hasCommittedContext || speechInProgress else {
            throw RealtimeClientError.noContext
        }

        if visibleResponseID != nil {
            return
        }
        if awaitingManualResponseCreated || pendingManualSend {
            return
        }

        manualTriggerPressedAt = Date()

        if speechInProgress {

            pendingManualSend = true
            return
        }

        try await sendManualResponseCreate()
    }

    private func sendManualResponseCreate() async throws {
        for _ in inFlightResponseIDs {

            try? await transport.send(.responseCancel)
        }

        awaitingManualResponseCreated = true
        let metadata = ["trigger": "manual", "correlation_id": UUID().uuidString]
        switch forceAnswerStrategy {
        case .systemItem:
            let itemID = Self.makeForceItemID()
            await contextWindow.trackForceItem(itemID)
            try await transport.send(.conversationItemCreate(ConversationItemPayload(
                id: itemID,
                role: .system,
                text: RealtimeInstructions.forceAnswerNow
            )))
            try await transport.send(.responseCreate(ResponseCreateOptions(
                instructions: nil,
                outputModalities: ["text"],
                metadata: metadata
            )))
        case .mergedInstructions:
            try await transport.send(.responseCreate(ResponseCreateOptions(
                instructions: instructions + "\n\n" + RealtimeInstructions.forceAnswerNow,
                outputModalities: ["text"],
                metadata: metadata
            )))
        }
    }

    public func resetContext() async {
        guard sessionActive else { return }
        for _ in inFlightResponseIDs {
            try? await transport.send(.responseCancel)
        }
        let idsToDelete = await contextWindow.takeAllForReset()
        for id in idsToDelete { try? await transport.send(.conversationItemDelete(itemID: id)) }
        try? await transport.send(.inputAudioBufferClear)
        trackers.removeAll()
        responseTrigger.removeAll()
        visibleResponseID = nil
        awaitingManualResponseCreated = false
        pendingManualSend = false
        windowStartedAt = nil
    }

    private static func makeForceItemID() -> String {
        makeItemID(prefix: "force_")
    }

    private static func makeItemID(prefix: String) -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return prefix + hex.prefix(16)
    }

    public func stop() async {
        sessionActive = false
        eventsTask?.cancel()
        eventsTask = nil
        await transport.close()
        resetSessionState()
    }

    private func resetSessionState() {
        contextWindow = AnswerContextWindow()
        trackers.removeAll()
        responseTrigger.removeAll()
        inFlightResponseIDs.removeAll()
        visibleResponseID = nil
        awaitingManualResponseCreated = false
        speechInProgress = false
        pendingManualSend = false
        windowStartedAt = nil
    }

    private func makeSessionConfig() -> SessionConfig {
        SessionConfig(
            model: Self.modelID,
            instructions: instructions,
            outputModalities: ["text"],
            audio: AudioConfig(input: AudioInputConfig(

                format: AudioFormatConfig(rate: 24_000),
                turnDetection: vadSettingsProvider().config
            )),
            reasoning: ReasoningConfig(effort: "low")
        )
    }

    private func startReceiveLoop() {
        eventsTask?.cancel()

        let stream = transport.events()
        eventsTask = Task { [weak self] in
            guard let self else { return }
            for await transportEvent in stream {
                if Task.isCancelled { return }
                await self.handle(transportEvent)
            }
        }
    }

    private func handle(_ transportEvent: RealtimeTransportEvent) async {
        switch transportEvent {
        case .serverEvent(let event):
            await handle(event)
        case .closed(let reason):
            await handleTransportClosed(reason: reason)
        case .failed(let reason):
            await handleTransportClosed(reason: reason)
        }
    }

    private func handle(_ event: RealtimeServerEvent) async {
        switch event {
        case .sessionCreated:
            redactedLog("realtime session.created received")
        case .sessionUpdated:
            redactedLog("realtime session.updated received")
        case .rateLimitsUpdated:
            break

        case .speechStarted:
            speechInProgress = true

        case .speechStopped:
            speechInProgress = false
            speechStoppedAt = Date()

        case .inputAudioBufferCommitted(let itemID, _):
            if windowStartedAt == nil { windowStartedAt = Date() }
            let evicted = await contextWindow.trackCommittedUserItem(itemID)
            for id in evicted { try? await transport.send(.conversationItemDelete(itemID: id)) }
            if pendingManualSend {
                pendingManualSend = false
                try? await sendManualResponseCreate()
            }

        case .conversationItemCreated:
            break

        case .responseCreated(let responseID, let metadata):
            inFlightResponseIDs.insert(responseID)
            responseCreatedAt[responseID] = Date()
            let trigger: AnswerTriggerKind
            if let echoed = metadata?["trigger"] {
                trigger = echoed == "manual" ? .manual : .automatic
            } else {
                trigger = awaitingManualResponseCreated ? .manual : .automatic
            }
            responseTrigger[responseID] = trigger
            if trigger == .manual {
                awaitingManualResponseCreated = false
                await contextWindow.bindForceItems(toResponse: responseID)
            }

        case .outputTextDelta(let responseID, _, let delta):
            handleOutputTextDelta(responseID: responseID, delta: delta)

        case .outputTextDone(let responseID, let itemID, let text):
            await handleOutputTextDone(responseID: responseID, itemID: itemID, text: text)

        case .responseDone(let responseID, let status, let outputItemIDs):
            await handleResponseDone(responseID: responseID, status: status, outputItemIDs: outputItemIDs)

        case .error(let message, let code):
            redactedLog("realtime error code=\(code ?? "-")")
            emit(.failed(code ?? message))

        case .unknown(let type):
            redactedLog("realtime unrecognized event type=\(type)")
        }
    }

    private func handleOutputTextDelta(responseID: String, delta: String) {
        var tracker = trackers[responseID] ?? ResponseTextTracker()
        guard !tracker.resolved else {
            if tracker.isReal, responseID == visibleResponseID {
                emit(.textDelta(responseID: responseID, text: delta))
            }
            return
        }

        tracker.buffer += delta
        let sentinel = RealtimeInstructions.waitForQuestionSentinel

        if sentinel.hasPrefix(tracker.buffer), tracker.buffer.count <= sentinel.count {

            trackers[responseID] = tracker
            return
        }

        resolveAsReal(responseID: responseID, bufferedText: tracker.buffer, tracker: &tracker)
        trackers[responseID] = tracker
    }

    private func handleOutputTextDone(responseID: String, itemID: String, text: String) async {
        var tracker = trackers[responseID] ?? ResponseTextTracker()

        if !tracker.resolved {
            let sentinel = RealtimeInstructions.waitForQuestionSentinel
            if text == sentinel {
                tracker.resolved = true
                tracker.isReal = false
                trackers[responseID] = tracker
                await contextWindow.trackAssistantOutputItem(responseID: responseID, itemID: itemID)
                let idsToDelete = await contextWindow.takeAssistantOutputItems(responseID: responseID)
                for id in idsToDelete { try? await transport.send(.conversationItemDelete(itemID: id)) }
                emit(.waitingForQuestion)
                return
            } else {
                resolveAsReal(responseID: responseID, bufferedText: text, tracker: &tracker)
                trackers[responseID] = tracker
            }
        }

        if tracker.isReal {
            await contextWindow.trackAssistantOutputItem(responseID: responseID, itemID: itemID)
        }
    }

    private func resolveAsReal(responseID: String, bufferedText: String, tracker: inout ResponseTextTracker) {
        tracker.resolved = true
        tracker.isReal = true

        guard visibleResponseID == nil else {

            return
        }
        visibleResponseID = responseID

        if let createdAt = responseCreatedAt[responseID] {
            let trigger = responseTrigger[responseID] ?? .automatic
            let now = Date()
            if trigger == .manual, let pressedAt = manualTriggerPressedAt {
                Task { [latencyRecording] in
                    await latencyRecording.record(.manualTriggerToFirstDeltaMs(Int(now.timeIntervalSince(pressedAt) * 1000)))
                }
            } else if let stoppedAt = speechStoppedAt {
                Task { [latencyRecording] in
                    await latencyRecording.record(.speechEndToFirstDeltaMs(Int(now.timeIntervalSince(stoppedAt) * 1000)))
                }
            }
            _ = createdAt
            if let windowStartedAt {
                Task { [latencyRecording] in
                    await latencyRecording.record(.contextDurationMs(Int(now.timeIntervalSince(windowStartedAt) * 1000), trigger: trigger))
                }
            }
        }

        emit(.responseStarted(responseID: responseID, trigger: responseTrigger[responseID] ?? .automatic))
        if !bufferedText.isEmpty {
            emit(.textDelta(responseID: responseID, text: bufferedText))
        }
    }

    private func handleResponseDone(responseID: String, status: String, outputItemIDs: [String]) async {
        inFlightResponseIDs.remove(responseID)
        defer { trackers[responseID] = nil; responseCreatedAt[responseID] = nil; responseTrigger[responseID] = nil }

        if status == "cancelled" {
            let tracked = await contextWindow.takeCancelledResponseOutput(responseID: responseID)
            var idsToDelete = tracked
            for id in outputItemIDs where !idsToDelete.contains(id) { idsToDelete.append(id) }
            for id in idsToDelete { try? await transport.send(.conversationItemDelete(itemID: id)) }
            if visibleResponseID == responseID { visibleResponseID = nil }
            emit(.cancelled(responseID: responseID, reason: "interrupted_by_speech"))
            return
        }

        let tracker = trackers[responseID] ?? ResponseTextTracker()
        guard tracker.resolved, tracker.isReal else {
            return
        }

        if visibleResponseID == responseID {
            if let createdAt = responseCreatedAt[responseID] {
                Task { [latencyRecording] in
                    await latencyRecording.record(.responseTotalMs(Int(Date().timeIntervalSince(createdAt) * 1000)))
                }
            }
            let idsToDelete = await contextWindow.takeAllForCleanup(respondedResponseID: responseID)
            for id in idsToDelete { try? await transport.send(.conversationItemDelete(itemID: id)) }
            visibleResponseID = nil
            windowStartedAt = nil
            emit(.completed(responseID: responseID))
        } else {

            let idsToDelete = await contextWindow.takeAssistantOutputItems(responseID: responseID)
            for id in idsToDelete { try? await transport.send(.conversationItemDelete(itemID: id)) }
        }
    }

    private func handleTransportClosed(reason: String?) async {
        guard sessionActive else { return }
        redactedLog("realtime transport closed, attempting reconnect: \(reason ?? "-")")

        var attempt = 0
        while attempt < maxReconnectAttempts, sessionActive {
            attempt += 1
            let jitterMs = Int.random(in: 0...250)
            let backoffMs = Self.milliseconds(reconnectBaseDelay) * (1 << (attempt - 1)) + jitterMs
            try? await Task.sleep(for: .milliseconds(backoffMs))
            guard sessionActive else { return }

            do {
                try await reconnect()
                redactedLog("realtime reconnect succeeded on attempt \(attempt)")
                return
            } catch {
                redactedLog("realtime reconnect attempt \(attempt) failed")
            }
        }

        if sessionActive {
            sessionActive = false
            emit(.failed("reconnect_exhausted"))
        }
    }

    private func reconnect() async throws {
        let reconnectStartedAt = Date()
        await transport.close()
        resetSessionState()
        let credential = try await Self.requireCredential(from: credentialProviding)
        try await transport.connect(url: Self.endpointURL, auth: .bearer(credential.apiKey))
        startReceiveLoop()
        try await transport.send(.sessionUpdate(makeSessionConfig()))
        await latencyRecording.record(.reconnectMs(Int(Date().timeIntervalSince(reconnectStartedAt) * 1000)))
    }

    private static func requireCredential(from provider: any RealtimeCredentialProviding) async throws -> RealtimeCredential {
        guard let credential = try? await provider.currentCredential(), !credential.apiKey.isEmpty else {
            throw RealtimeClientError.notAuthenticated
        }
        return credential
    }

    private func emit(_ event: RealtimeAnswerEvent) {
        publicContinuation.yield(event)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
