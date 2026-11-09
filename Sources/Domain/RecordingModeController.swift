import Foundation

public actor RecordingModeController: ModeController {
    private let systemAudio: any SystemAudioCapturing
    private let microphone: any MicrophoneCapturing
    private let transcribing: any LocalTranscribing
    private let repository: any MeetingRepository
    private let latencyRecording: (any LatencyRecording)?
    private let audioRecording: (any MeetingAudioRecording)?
    private let isAudioStorageEnabled: @Sendable () -> Bool
    private let chunkDurationSeconds: Double
    private let overlapSeconds: Double
    private let backpressureCapacity: Int
    private var audioRecordingActive = false

    private var systemAudioProducerTask: Task<Void, Never>?
    private var microphoneProducerTask: Task<Void, Never>?
    private var systemAudioConsumerTask: Task<Void, Never>?
    private var microphoneConsumerTask: Task<Void, Never>?
    private var systemAudioLease: ResourceLease?
    private var microphoneLease: ResourceLease?

    private var meetingID: MeetingID?
    private var systemAudioChannel: RecordingBackpressureChannel?
    private var microphoneChannel: RecordingBackpressureChannel?
    private var systemAudioPipeline: ChunkedTranscriptionPipeline?
    private var microphonePipeline: ChunkedTranscriptionPipeline?

    private let failureStream: AsyncStream<String>
    private let failureContinuation: AsyncStream<String>.Continuation

    private let transcriptStream: AsyncStream<TranscribedSegment>
    private let transcriptContinuation: AsyncStream<TranscribedSegment>.Continuation

    private let finishedMeetingStream: AsyncStream<MeetingID>
    private let finishedMeetingContinuation: AsyncStream<MeetingID>.Continuation

    public init(
        systemAudio: any SystemAudioCapturing,
        microphone: any MicrophoneCapturing,
        transcribing: any LocalTranscribing,
        repository: any MeetingRepository,
        latencyRecording: (any LatencyRecording)? = nil,
        audioRecording: (any MeetingAudioRecording)? = nil,
        isAudioStorageEnabled: @escaping @Sendable () -> Bool = { false },
        chunkDurationSeconds: Double = 8,
        overlapSeconds: Double = 1.5,
        backpressureCapacity: Int = 400
    ) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.transcribing = transcribing
        self.repository = repository
        self.latencyRecording = latencyRecording
        self.audioRecording = audioRecording
        self.isAudioStorageEnabled = isAudioStorageEnabled
        self.chunkDurationSeconds = chunkDurationSeconds
        self.overlapSeconds = overlapSeconds
        self.backpressureCapacity = backpressureCapacity
        (self.failureStream, self.failureContinuation) = AsyncStream<String>.makeStream()
        (self.transcriptStream, self.transcriptContinuation) = AsyncStream<TranscribedSegment>.makeStream()
        (self.finishedMeetingStream, self.finishedMeetingContinuation) = AsyncStream<MeetingID>.makeStream()
    }

    public func start() async throws {
        let meetingID = try await repository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)
        self.meetingID = meetingID

        audioRecordingActive = audioRecording != nil && isAudioStorageEnabled()
        if audioRecordingActive {
            await audioRecording?.start(meetingID: meetingID)
        }

        let systemChannel = RecordingBackpressureChannel(capacity: backpressureCapacity)
        let micChannel = RecordingBackpressureChannel(capacity: backpressureCapacity)
        systemAudioChannel = systemChannel
        microphoneChannel = micChannel

        let systemPipeline = ChunkedTranscriptionPipeline(
            transcribing: transcribing,
            chunkDurationSeconds: chunkDurationSeconds,
            overlapSeconds: overlapSeconds
        )
        let micPipeline = ChunkedTranscriptionPipeline(
            transcribing: transcribing,
            chunkDurationSeconds: chunkDurationSeconds,
            overlapSeconds: overlapSeconds
        )
        systemAudioPipeline = systemPipeline
        microphonePipeline = micPipeline

        let sysFrames = try await systemAudio.start(scope: .defaultScope).frames
        let systemAudio = self.systemAudio
        systemAudioLease = ResourceLease(name: "systemAudio") { await systemAudio.stop() }

        let micFrames = try await microphone.start()
        let microphone = self.microphone
        microphoneLease = ResourceLease(name: "microphone") { await microphone.stop() }

        systemAudioProducerTask = Task {
            for await frame in sysFrames {
                if Task.isCancelled { break }
                await systemChannel.send(frame)
            }
            await systemChannel.finish()
        }
        microphoneProducerTask = Task {
            for await frame in micFrames {
                if Task.isCancelled { break }
                await micChannel.send(frame)
            }
            await micChannel.finish()
        }

        systemAudioConsumerTask = Task { [weak self] in
            await self?.consume(channel: systemChannel, pipeline: systemPipeline)
        }
        microphoneConsumerTask = Task { [weak self] in
            await self?.consume(channel: micChannel, pipeline: micPipeline)
        }
    }

    public func stop() async {
        systemAudioProducerTask?.cancel()
        microphoneProducerTask?.cancel()

        await systemAudioLease?.release(); systemAudioLease = nil
        await microphoneLease?.release(); microphoneLease = nil

        await systemAudioProducerTask?.value; systemAudioProducerTask = nil
        await microphoneProducerTask?.value; microphoneProducerTask = nil
        await systemAudioConsumerTask?.value; systemAudioConsumerTask = nil
        await microphoneConsumerTask?.value; microphoneConsumerTask = nil

        if let systemAudioPipeline { await flush(pipeline: systemAudioPipeline) }
        if let microphonePipeline { await flush(pipeline: microphonePipeline) }

        if let systemAudioChannel {
            let dropped = await systemAudioChannel.droppedFrameCount
            if dropped > 0 { await latencyRecording?.record(.droppedAudioFrames(dropped)) }
        }
        if let microphoneChannel {
            let dropped = await microphoneChannel.droppedFrameCount
            if dropped > 0 { await latencyRecording?.record(.droppedAudioFrames(dropped)) }
        }

        if let meetingID {
            let finishedSuccessfully = (try? await repository.finish(meetingID: meetingID, endedAt: Date())) != nil
            if finishedSuccessfully {
                finishedMeetingContinuation.yield(meetingID)
            }
        }

        if audioRecordingActive {
            await audioRecording?.finish()
            audioRecordingActive = false
        }

        meetingID = nil
        systemAudioChannel = nil
        microphoneChannel = nil
        systemAudioPipeline = nil
        microphonePipeline = nil
    }

    nonisolated public func failures() -> AsyncStream<String> {
        failureStream
    }

    nonisolated public func transcriptEvents() -> AsyncStream<TranscribedSegment> {
        transcriptStream
    }

    nonisolated public func finishedMeetings() -> AsyncStream<MeetingID> {
        finishedMeetingStream
    }

    private func consume(channel: RecordingBackpressureChannel, pipeline: ChunkedTranscriptionPipeline) async {
        while let frame = await channel.next() {
            if audioRecordingActive {
                await audioRecording?.write(frame)
            }
            let shouldFlush = await pipeline.ingest(frame)
            if shouldFlush {
                await flush(pipeline: pipeline)
            }
        }
    }

    private func flush(pipeline: ChunkedTranscriptionPipeline) async {
        guard let meetingID else { return }
        do {
            let segments = try await pipeline.flush()
            for segment in segments {
                try await repository.appendSegment(segment, meetingID: meetingID)
                transcriptContinuation.yield(segment)
            }
        } catch {
            failureContinuation.yield("transcription_failed: \(error)")
        }
    }
}
