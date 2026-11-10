import Domain
import Foundation

public actor OpenAIRealtimeTranscriptionClient: MeTranscribing {
    public static let modelID = "gpt-live-transcribe"
    public static let sampleRate = 24_000
    static let minimumCommitSamples = sampleRate / 10

    static var endpointURL: URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        return components.url!
    }

    private let transport: any RealtimeWebSocketTransport
    private let credentialProviding: any RealtimeCredentialProviding
    private let delay: String
    private let reconnectBaseDelay: Duration
    private let maxReconnectDelay: Duration
    private let maxReconnectAttempts: Int
    private let redactedLog: @Sendable (String) -> Void
    private let status = AsyncBroadcaster<MeTranscriptionStatus>(replayLatest: true, initial: .stopped)

    private var languages: [String] = []
    private var keywords: [String] = []
    private let keywordsProvider: @Sendable () async -> [String]
    private var active = false
    private var connected = false
    private var generation = 0
    private var eventsTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var deltaContinuation: AsyncStream<TranscriptDelta>.Continuation?
    private var samplesSinceCommit = 0
    private var partials: [String: String] = [:]
    private var finalizedItemIDs: Set<String> = []
    private var droppedForeignRateFrames = 0

    public init(
        transport: any RealtimeWebSocketTransport = URLSessionRealtimeWebSocketTransport(),
        credentialProviding: any RealtimeCredentialProviding,
        delay: String = "low",
        reconnectBaseDelay: Duration = .milliseconds(500),
        maxReconnectDelay: Duration = .seconds(8),
        maxReconnectAttempts: Int = 5,
        keywordsProvider: @escaping @Sendable () async -> [String] = { [] },
        redactedLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.keywordsProvider = keywordsProvider
        self.transport = transport
        self.credentialProviding = credentialProviding
        self.delay = delay
        self.reconnectBaseDelay = reconnectBaseDelay
        self.maxReconnectDelay = maxReconnectDelay
        self.maxReconnectAttempts = maxReconnectAttempts
        self.redactedLog = redactedLog
    }

    nonisolated public func statusUpdates() -> AsyncStream<MeTranscriptionStatus> {
        status.subscribe("meTranscriptionStatus-\(UUID().uuidString)")
    }

    var droppedForeignRateFrameCount: Int { droppedForeignRateFrames }

    public func start(languages: [String]) async throws -> AsyncStream<TranscriptDelta> {
        if active { await stop() }
        self.languages = languages
        keywords = ProfileKeywordExtractor.sanitized(await keywordsProvider())
        status.yield(.connecting)
        let (stream, continuation) = AsyncStream<TranscriptDelta>.makeStream()
        do {
            try await connect()
        } catch {
            status.yield(.unavailable(reason: "connect_failed"))
            continuation.finish()
            throw error
        }
        deltaContinuation = continuation
        active = true
        status.yield(.live)
        redactedLog("me transcription session started (model=\(Self.modelID))")
        return stream
    }

    public func appendAudio(_ frame: PCMAudioFrame) async {
        guard active, connected, !frame.samples.isEmpty else { return }
        guard frame.sampleRate == Self.sampleRate, frame.channelCount == 1 else {
            droppedForeignRateFrames += 1
            return
        }
        let data = frame.samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try await transport.send(.inputAudioBufferAppend(audioBase64: data.base64EncodedString()))
            samplesSinceCommit += frame.samples.count
        } catch {
            redactedLog("me transcription append failed")
        }
    }

    public func commitTurn() async {
        guard active, connected, samplesSinceCommit > 0 else { return }
        let enough = samplesSinceCommit >= Self.minimumCommitSamples
        samplesSinceCommit = 0
        try? await transport.send(enough ? .inputAudioBufferCommit : .inputAudioBufferClear)
    }

    public func stop() async {
        let wasActive = active
        active = false
        connected = false
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        eventsTask?.cancel()
        eventsTask = nil
        if wasActive {
            await transport.close()
        }
        flushPartials()
        deltaContinuation?.finish()
        deltaContinuation = nil
        samplesSinceCommit = 0
        finalizedItemIDs.removeAll()
        status.yield(.stopped)
    }

    private func connect() async throws {
        let credential = try await Self.requireCredential(from: credentialProviding)
        try await transport.connect(url: Self.endpointURL, auth: .bearer(credential.apiKey))
        generation += 1
        startReceiveLoop(generation: generation)
        try await transport.send(.transcriptionSessionUpdate(TranscriptionSessionConfig(
            model: Self.modelID,
            rate: Self.sampleRate,
            languages: languages,
            delay: delay,
            keywords: keywords
        )))
        connected = true
        samplesSinceCommit = 0
    }

    private func startReceiveLoop(generation: Int) {
        eventsTask?.cancel()
        let stream = transport.events()
        eventsTask = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.handle(event, generation: generation)
            }
        }
    }

    private func handle(_ transportEvent: RealtimeTransportEvent, generation: Int) {
        guard generation == self.generation, active else { return }
        switch transportEvent {
        case .serverEvent(let event):
            handle(event)
        case .closed(let reason):
            connectionDropped(reason: reason ?? "closed")
        case .failed(let reason):
            connectionDropped(reason: reason)
        }
    }

    private func handle(_ event: RealtimeServerEvent) {
        switch event {
        case .inputAudioTranscriptionDelta(let itemID, let delta):
            guard !finalizedItemIDs.contains(itemID), !delta.isEmpty else { return }
            let text = (partials[itemID] ?? "") + delta
            partials[itemID] = text
            deltaContinuation?.yield(TranscriptDelta(itemID: itemID, text: text, isFinal: false, source: .remote))
        case .inputAudioTranscriptionCompleted(let itemID, let transcript, let language):
            guard finalizedItemIDs.insert(itemID).inserted else { return }
            partials[itemID] = nil
            deltaContinuation?.yield(TranscriptDelta(itemID: itemID, text: transcript, isFinal: true, source: .remote, language: language))
        case .inputAudioTranscriptionFailed(let itemID, _):
            redactedLog("me transcription failed for item")
            finalize(itemID: itemID)
        case .error(_, let code):
            redactedLog("me transcription error code=\(code ?? "-")")
        default:
            break
        }
    }

    private func finalize(itemID: String) {
        guard finalizedItemIDs.insert(itemID).inserted else { return }
        let text = partials.removeValue(forKey: itemID) ?? ""
        deltaContinuation?.yield(TranscriptDelta(itemID: itemID, text: text, isFinal: true, source: .remote))
    }

    private func flushPartials() {
        for itemID in partials.keys.sorted() {
            finalize(itemID: itemID)
        }
    }

    private func connectionDropped(reason: String) {
        guard active, connected else { return }
        connected = false
        generation += 1
        eventsTask?.cancel()
        eventsTask = nil
        samplesSinceCommit = 0
        flushPartials()
        redactedLog("me transcription connection dropped: \(reason)")
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop()
        }
    }

    private func reconnectLoop() async {
        var attempt = 0
        while active, attempt < maxReconnectAttempts {
            attempt += 1
            status.yield(.reconnecting(attempt: attempt))
            try? await Task.sleep(for: backoff(attempt: attempt))
            guard active, !Task.isCancelled else { return }
            await transport.close()
            do {
                try await connect()
                status.yield(.live)
                reconnectTask = nil
                redactedLog("me transcription reconnected on attempt \(attempt)")
                return
            } catch {
                redactedLog("me transcription reconnect attempt \(attempt) failed")
            }
        }
        guard active else { return }
        active = false
        reconnectTask = nil
        deltaContinuation?.finish()
        deltaContinuation = nil
        status.yield(.unavailable(reason: "reconnect_exhausted"))
    }

    private func backoff(attempt: Int) -> Duration {
        let base = Self.milliseconds(reconnectBaseDelay) * (1 << min(attempt - 1, 10))
        let capped = min(base, Self.milliseconds(maxReconnectDelay))
        let jitter = Int.random(in: 0...max(1, capped / 5))
        return .milliseconds(capped + jitter)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }

    private static func requireCredential(from provider: any RealtimeCredentialProviding) async throws -> RealtimeCredential {
        guard let credential = try? await provider.currentCredential(), !credential.apiKey.isEmpty else {
            throw RealtimeClientError.notAuthenticated
        }
        return credential
    }
}
