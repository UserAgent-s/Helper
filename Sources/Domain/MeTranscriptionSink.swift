import Foundation

public actor MeTranscriptionSink {
    public static let consumer = "answers.me"

    private let captureHub: CaptureHub
    private let transcriber: any MeTranscribing
    private let responder: any LiveResponder
    private let languages: @Sendable () -> [String]
    private let preRollMs: Int
    private let dedupGrace: Duration
    private let now: @Sendable () -> Date
    private let redactedLog: @Sendable (String) -> Void
    private let transcriptBroadcaster = AsyncBroadcaster<TranscriptEvent>()

    private var vad: ClientVoiceActivityDetector
    private var echo: EchoSuppressor
    private var running = false
    private var generation = 0
    private var microphone: CaptureSubscription?
    private var levelsSubscriptionID: UUID?
    private var framesTask: Task<Void, Never>?
    private var levelsTask: Task<Void, Never>?
    private var deltasTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var preRoll: [PCMAudioFrame] = []
    private var preRollSamples = 0
    private var noticedGeneration: Int?

    public private(set) var processedFrameCount = 0
    public private(set) var droppedEchoCount = 0
    public private(set) var injectedCount = 0
    public private(set) var committedTurnCount = 0

    public init(
        captureHub: CaptureHub,
        transcriber: any MeTranscribing,
        responder: any LiveResponder,
        languages: @escaping @Sendable () -> [String] = { ["ru", "en"] },
        vadConfiguration: ClientVADConfiguration = ClientVADConfiguration(),
        echoConfiguration: EchoSuppressorConfiguration = EchoSuppressorConfiguration(),
        preRollMs: Int = 300,
        dedupGrace: Duration = .seconds(1),
        now: @escaping @Sendable () -> Date = { Date() },
        redactedLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.captureHub = captureHub
        self.transcriber = transcriber
        self.responder = responder
        self.languages = languages
        self.vad = ClientVoiceActivityDetector(configuration: vadConfiguration)
        self.echo = EchoSuppressor(configuration: echoConfiguration)
        self.preRollMs = preRollMs
        self.dedupGrace = dedupGrace
        self.now = now
        self.redactedLog = redactedLog
    }

    nonisolated public func transcripts(subscriber: String = #fileID) -> AsyncStream<TranscriptEvent> {
        transcriptBroadcaster.subscribe(subscriber)
    }

    public var isRunning: Bool { running }

    @discardableResult
    public func start() async -> Bool {
        if running { await stop() }
        running = true
        generation += 1
        let generation = self.generation
        vad.reset()
        echo.reset()
        clearPreRoll()

        let statuses = transcriber.statusUpdates()
        statusTask = Task { [weak self] in
            for await status in statuses {
                if Task.isCancelled { return }
                guard case .unavailable(let reason) = status else { continue }
                await self?.noticeUnavailable(reason: reason, generation: generation)
            }
        }

        let deltas: AsyncStream<TranscriptDelta>
        do {
            deltas = try await transcriber.start(languages: languages())
        } catch {
            redactedLog("me channel transcriber start failed")
            noticeUnavailable(reason: "connect_failed", generation: generation)
            await teardown(stopTranscriber: true)
            return false
        }
        guard isCurrent(generation) else {
            await transcriber.stop()
            return false
        }

        let subscription: CaptureSubscription
        do {
            subscription = try await captureHub.acquire(.microphone, consumer: Self.consumer, policy: .bufferingNewest(250), microphoneProfile: .me)
        } catch {
            redactedLog("me channel microphone unavailable")
            noticeUnavailable(reason: "microphone_unavailable", generation: generation)
            await teardown(stopTranscriber: true)
            return false
        }
        guard isCurrent(generation) else {
            await captureHub.release(subscription)
            await transcriber.stop()
            return false
        }
        microphone = subscription

        let (levelsID, levels) = captureHub.levels.identifiedSubscription(Self.consumer, policy: .bufferingNewest(16))
        levelsSubscriptionID = levelsID
        levelsTask = Task { [weak self] in
            for await level in levels where level.kind == .systemAudio {
                if Task.isCancelled { return }
                await self?.noteSystemLevel(level)
            }
        }
        deltasTask = Task { [weak self] in
            for await delta in deltas {
                if Task.isCancelled { return }
                await self?.handle(delta, generation: generation)
            }
        }
        framesTask = Task { [weak self] in
            for await frame in subscription.frames {
                if Task.isCancelled { return }
                await self?.process(frame)
            }
        }
        redactedLog("me channel started")
        return true
    }

    public func stop() async {
        guard running else { return }
        await teardown(stopTranscriber: true)
        redactedLog("me channel stopped")
    }

    public func noteRemoteTranscript(_ event: TranscriptEvent) {
        guard running, event.speaker == .them else { return }
        echo.noteRemoteTranscript(itemID: event.itemID, text: event.text, at: now())
    }

    private func teardown(stopTranscriber: Bool) async {
        running = false
        generation += 1
        framesTask?.cancel(); framesTask = nil
        deltasTask?.cancel(); deltasTask = nil
        levelsTask?.cancel(); levelsTask = nil
        if let levelsSubscriptionID { captureHub.levels.cancelSubscription(levelsSubscriptionID) }
        levelsSubscriptionID = nil
        if let microphone { await captureHub.release(microphone) }
        microphone = nil
        if stopTranscriber { await transcriber.stop() }
        statusTask?.cancel(); statusTask = nil
        vad.reset()
        echo.reset()
        clearPreRoll()
    }

    private func noticeUnavailable(reason: String, generation: Int) {
        guard generation == self.generation, noticedGeneration != generation else { return }
        noticedGeneration = generation
        captureHub.notices.yield(.meTranscriptionUnavailable(reason: reason))
    }

    private func isCurrent(_ generation: Int) -> Bool {
        running && generation == self.generation
    }

    private func noteSystemLevel(_ level: AudioLevel) {
        echo.noteSystemLevel(level.rmsDBFS, at: level.at)
    }

    private func process(_ frame: PCMAudioFrame) async {
        guard running else { return }
        processedFrameCount += 1
        let wasOpen = vad.isOpen
        if wasOpen {
            await transcriber.appendAudio(frame)
        } else {
            appendPreRoll(frame)
        }
        let events = vad.ingest(frame, openingAllowed: echo.allowsOpening(at: frame.capturedAt))
        for event in events {
            switch event {
            case .opened:
                let buffered = preRoll
                clearPreRoll()
                for buffered in buffered { await transcriber.appendAudio(buffered) }
            case .closed:
                committedTurnCount += 1
                await transcriber.commitTurn()
            }
        }
    }

    private func appendPreRoll(_ frame: PCMAudioFrame) {
        preRoll.append(frame)
        preRollSamples += frame.samples.count
        let limit = max(0, frame.sampleRate * max(1, frame.channelCount) * preRollMs / 1000)
        while preRollSamples > limit, preRoll.count > 1 {
            preRollSamples -= preRoll.removeFirst().samples.count
        }
    }

    private func clearPreRoll() {
        preRoll.removeAll()
        preRollSamples = 0
    }

    private func handle(_ delta: TranscriptDelta, generation: Int) async {
        guard isCurrent(generation), delta.isFinal else { return }
        let text = delta.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if dedupGrace > .zero {
            let grace = dedupGrace
            Task { [weak self] in
                try? await Task.sleep(for: grace)
                await self?.deliver(itemID: delta.itemID, text: text, language: delta.language, generation: generation)
            }
        } else {
            await deliver(itemID: delta.itemID, text: text, language: delta.language, generation: generation)
        }
    }

    private func deliver(itemID: String, text: String, language: String?, generation: Int) async {
        guard isCurrent(generation) else { return }
        guard !echo.isEchoDuplicate(text, at: now()) else {
            droppedEchoCount += 1
            redactedLog("me channel dropped echo duplicate")
            return
        }
        do {
            try await responder.injectContext(.me(text))
            injectedCount += 1
        } catch {
            redactedLog("me channel inject failed")
        }
        guard isCurrent(generation) else { return }
        transcriptBroadcaster.yield(TranscriptEvent(speaker: .me, itemID: itemID, text: text, language: language, isFinal: true))
    }
}
