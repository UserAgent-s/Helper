import Foundation

public struct CaptureSubscription: Sendable, Equatable {
    public let id: UUID
    public let kind: AudioSourceKind
    public let consumer: String
    public let frames: AsyncStream<PCMAudioFrame>

    public static func == (lhs: CaptureSubscription, rhs: CaptureSubscription) -> Bool {
        lhs.id == rhs.id
    }
}

public actor CaptureHub {
    private struct ActiveSource {
        let broadcaster: AsyncBroadcaster<PCMAudioFrame>
        var lease: ResourceLease
        var pumpTask: Task<Void, Never>?
        var noticesTask: Task<Void, Never>?
        var subscriptionIDs: Set<UUID> = []
        var consumerNames: Set<String> = []
        var effectiveScope: SystemAudioScope?
        var deviceUID: String?
        var generation = UUID()
    }

    private let system: any SystemAudioCapturing
    private let microphone: any MicrophoneCapturing
    private let scope: @Sendable () async -> SystemAudioScope
    private let microphonePlan: @Sendable () async -> MicrophoneStartPlan
    public nonisolated let notices: AsyncBroadcaster<CaptureNotice>
    public nonisolated let levels: AsyncBroadcaster<AudioLevel>

    private var sources: [AudioSourceKind: ActiveSource] = [:]
    private var startOrder: [AudioSourceKind] = []
    private var droppedByConsumer: [String: Int] = [:]

    private let failureStream: AsyncStream<String>
    private let failureContinuation: AsyncStream<String>.Continuation

    public init(
        system: any SystemAudioCapturing,
        microphone: any MicrophoneCapturing,
        scope: @escaping @Sendable () async -> SystemAudioScope = { .defaultScope },
        microphonePlan: @escaping @Sendable () async -> MicrophoneStartPlan = { MicrophoneStartPlan() },
        notices: AsyncBroadcaster<CaptureNotice> = AsyncBroadcaster<CaptureNotice>(),
        levels: AsyncBroadcaster<AudioLevel> = AsyncBroadcaster<AudioLevel>(replayLatest: true)
    ) {
        self.system = system
        self.microphone = microphone
        self.scope = scope
        self.microphonePlan = microphonePlan
        self.notices = notices
        self.levels = levels
        (failureStream, failureContinuation) = AsyncStream<String>.makeStream()
    }

    public var activeSources: Set<AudioSourceKind> {
        Set(sources.keys)
    }

    public var microphoneDeviceUID: String? {
        sources[.microphone]?.deviceUID
    }

    public func handleDeviceChange(_ change: AudioDeviceChange) async {
        guard let source = sources[.microphone] else { return }
        switch change {
        case .microphoneEngineReconfigured:
            break
        case .deviceListChanged, .defaultInputChanged:
            let plan = await microphonePlan()
            guard plan.options.deviceUID != source.deviceUID else { return }
        case .defaultOutputChanged, .outputDataSourceChanged:
            return
        }
        do {
            try await restart(.microphone)
        } catch {
            failureContinuation.yield("microphone_restart_failed")
            await stopSource(.microphone)
        }
    }

    public var systemEffectiveScope: SystemAudioScope? {
        sources[.systemAudio]?.effectiveScope
    }

    nonisolated public func failures() -> AsyncStream<String> {
        failureStream
    }

    public func acquire(_ kind: AudioSourceKind, consumer: String, policy: BroadcastBufferPolicy = .unbounded) async throws -> CaptureSubscription {
        if sources[kind] == nil {
            try await startSource(kind)
        }
        guard var source = sources[kind] else {
            throw CaptureHubError.sourceUnavailable(kind)
        }
        let (id, frames) = source.broadcaster.identifiedSubscription(consumer, policy: policy)
        source.subscriptionIDs.insert(id)
        source.consumerNames.insert(consumer)
        sources[kind] = source
        return CaptureSubscription(id: id, kind: kind, consumer: consumer, frames: frames)
    }

    public func release(_ subscription: CaptureSubscription) async {
        guard var source = sources[subscription.kind], source.subscriptionIDs.contains(subscription.id) else { return }
        source.broadcaster.cancelSubscription(subscription.id)
        source.subscriptionIDs.remove(subscription.id)
        sources[subscription.kind] = source
        if source.subscriptionIDs.isEmpty {
            await stopSource(subscription.kind)
        }
    }

    public func restart(_ kind: AudioSourceKind) async throws {
        guard let source = sources[kind] else { return }
        let generation = UUID()
        var retiring = source
        retiring.generation = generation
        sources[kind] = retiring
        source.noticesTask?.cancel()
        await source.lease.release()
        let started = try await startCapture(kind)
        guard var updated = sources[kind], updated.generation == generation else {
            await started.lease.release()
            return
        }
        updated.lease = started.lease
        updated.pumpTask = makePump(kind: kind, frames: started.frames, broadcaster: source.broadcaster, generation: generation)
        updated.noticesTask = makeNoticeForwarder(started.laterNotices)
        updated.effectiveScope = started.effectiveScope
        updated.deviceUID = started.deviceUID
        sources[kind] = updated
    }

    public func stopAll() async {
        for kind in startOrder.reversed() {
            await stopSource(kind)
        }
    }

    public func droppedFrames(consumer: String) -> Int {
        var total = droppedByConsumer[consumer] ?? 0
        for source in sources.values {
            total += source.broadcaster.droppedCount(for: consumer)
        }
        return total
    }

    private struct StartedCapture {
        let frames: AsyncStream<PCMAudioFrame>
        let effectiveScope: SystemAudioScope?
        let laterNotices: AsyncStream<CaptureNotice>?
        let lease: ResourceLease
        var deviceUID: String?
    }

    private func startCapture(_ kind: AudioSourceKind) async throws -> StartedCapture {
        switch kind {
        case .systemAudio:
            let requested = await scope()
            let start = try await system.start(scope: requested)
            if let notice = start.notice {
                notices.yield(notice)
            }
            let system = self.system
            return StartedCapture(
                frames: start.frames,
                effectiveScope: start.effectiveScope,
                laterNotices: start.laterNotices,
                lease: ResourceLease(name: "systemAudio") { await system.stop() }
            )
        case .microphone:
            let plan = await microphonePlan()
            if let notice = plan.notice {
                notices.yield(notice)
            }
            let frames = try await microphone.start(options: plan.options)
            let microphone = self.microphone
            return StartedCapture(
                frames: frames,
                effectiveScope: nil,
                laterNotices: nil,
                lease: ResourceLease(name: "microphone") { await microphone.stop() },
                deviceUID: plan.options.deviceUID
            )
        }
    }

    private func startSource(_ kind: AudioSourceKind) async throws {
        let started: StartedCapture
        do {
            started = try await startCapture(kind)
        } catch {
            switch kind {
            case .systemAudio: await system.stop()
            case .microphone: await microphone.stop()
            }
            throw error
        }
        let broadcaster = AsyncBroadcaster<PCMAudioFrame>()
        let generation = UUID()
        sources[kind] = ActiveSource(
            broadcaster: broadcaster,
            lease: started.lease,
            pumpTask: makePump(kind: kind, frames: started.frames, broadcaster: broadcaster, generation: generation),
            noticesTask: makeNoticeForwarder(started.laterNotices),
            effectiveScope: started.effectiveScope,
            deviceUID: started.deviceUID,
            generation: generation
        )
        startOrder.removeAll { $0 == kind }
        startOrder.append(kind)
    }

    private func makePump(kind: AudioSourceKind, frames: AsyncStream<PCMAudioFrame>, broadcaster: AsyncBroadcaster<PCMAudioFrame>, generation: UUID) -> Task<Void, Never> {
        let levels = self.levels
        return Task { [weak self] in
            var meter = AudioLevelMeter()
            for await frame in frames {
                if Task.isCancelled { break }
                broadcaster.yield(frame)
                if let level = meter.ingest(frame) {
                    levels.yield(level)
                }
            }
            if !Task.isCancelled {
                await self?.sourceEndedUnexpectedly(kind, generation: generation)
            }
        }
    }

    private func makeNoticeForwarder(_ laterNotices: AsyncStream<CaptureNotice>?) -> Task<Void, Never>? {
        guard let laterNotices else { return nil }
        let notices = self.notices
        return Task {
            for await notice in laterNotices {
                notices.yield(notice)
            }
        }
    }

    private func sourceEndedUnexpectedly(_ kind: AudioSourceKind, generation: UUID) async {
        guard let source = sources[kind], source.generation == generation else { return }
        failureContinuation.yield("\(kind.rawValue)_capture_ended")
        await stopSource(kind)
    }

    private func stopSource(_ kind: AudioSourceKind) async {
        guard let source = sources.removeValue(forKey: kind) else { return }
        startOrder.removeAll { $0 == kind }
        source.pumpTask?.cancel()
        source.noticesTask?.cancel()
        for name in source.consumerNames {
            droppedByConsumer[name, default: 0] += source.broadcaster.droppedCount(for: name)
        }
        await source.lease.release()
        source.broadcaster.finish()
    }
}

public enum CaptureHubError: Error, Sendable, Equatable {
    case sourceUnavailable(AudioSourceKind)
}
