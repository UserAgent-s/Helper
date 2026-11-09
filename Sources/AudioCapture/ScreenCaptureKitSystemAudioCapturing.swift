import CoreMedia
import Domain
import Foundation
import ScreenCaptureKit

public final class ScreenCaptureKitSystemAudioCapturing: NSObject, SystemAudioCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let restartDelay: Duration = .milliseconds(500)

    private let outputFormat: AudioCaptureOutputFormat
    private let permissions: any PermissionsChecking
    private let contentProvider: any ShareableContentProviding
    private let ownBundleID: String
    private let captureQueue = DispatchQueue(label: "com.local.UserAgent057.audiocapture.system")
    private let stateLock = NSLock()

    private var activeStream: SCStream?
    private var continuation: AsyncStream<PCMAudioFrame>.Continuation?
    private var noticeContinuation: AsyncStream<CaptureNotice>.Continuation?
    private var realtimeConverter = RealtimeAudioFormatConverter()
    private var activeFilter: SCContentFilter?
    private var activeConfiguration: SCStreamConfiguration?
    private var didAttemptRestart = false

    public convenience init(outputFormat: AudioCaptureOutputFormat, permissions: any PermissionsChecking = SystemPermissionsChecker()) {
        self.init(
            outputFormat: outputFormat,
            permissions: permissions,
            contentProvider: ScreenCaptureKitShareableContentProvider(),
            ownBundleID: Bundle.main.bundleIdentifier ?? ""
        )
    }

    init(outputFormat: AudioCaptureOutputFormat, permissions: any PermissionsChecking, contentProvider: any ShareableContentProviding, ownBundleID: String) {
        self.outputFormat = outputFormat
        self.permissions = permissions
        self.contentProvider = contentProvider
        self.ownBundleID = ownBundleID
        super.init()
    }

    private func withLockedState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    public func start(scope: SystemAudioScope) async throws -> SystemAudioCaptureStart {
        let (snapshot, resolved) = try await SystemAudioCaptureResolver.resolve(
            scope: scope,
            provider: contentProvider,
            permissions: permissions,
            ownBundleID: ownBundleID
        )
        guard let content = snapshot.content, let display = content.displays.first else {
            throw AudioCaptureError.noDisplayAvailable
        }
        let filter = Self.makeFilter(resolved.plan, display: display, applications: content.applications)
        let configuration = makeConfiguration()

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)

        let (audioStream, audioContinuation) = AsyncStream<PCMAudioFrame>.makeStream()
        let (noticeStream, noticeStreamContinuation) = AsyncStream<CaptureNotice>.makeStream()
        withLockedState {
            activeStream = newStream
            continuation = audioContinuation
            noticeContinuation = noticeStreamContinuation
            realtimeConverter = RealtimeAudioFormatConverter()
            activeFilter = filter
            activeConfiguration = configuration
            didAttemptRestart = false
        }

        do {
            try await newStream.startCapture()
        } catch {
            finishStreams()
            throw error
        }
        return SystemAudioCaptureStart(
            frames: audioStream,
            effectiveScope: resolved.effectiveScope,
            notice: resolved.notice,
            laterNotices: noticeStream
        )
    }

    static func makeFilter(_ plan: SystemAudioFilterPlan, display: SCDisplay, applications: [SCRunningApplication]) -> SCContentFilter {
        switch plan {
        case .display(let excludedBundleIDs):
            let excluded = applications.filter { excludedBundleIDs.contains($0.bundleIdentifier) }
            return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        case .applications(let bundleIDs):
            let included = applications.filter { bundleIDs.contains($0.bundleIdentifier) }
            return SCContentFilter(display: display, including: included, exceptingWindows: [])
        }
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = outputFormat.targetSampleRate
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        return configuration
    }

    public func stop() async {
        let streamToStop = withLockedState { () -> SCStream? in
            let streamToStop = activeStream
            activeStream = nil
            activeFilter = nil
            activeConfiguration = nil
            continuation?.finish()
            continuation = nil
            noticeContinuation?.finish()
            noticeContinuation = nil
            return streamToStop
        }

        if let streamToStop {
            try? await streamToStop.stopCapture()
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        guard let frame = PCMAudioFrameExtraction.makeFrame(from: sampleBuffer, source: .systemAudio) else { return }

        let (cont, chunksToYield): (AsyncStream<PCMAudioFrame>.Continuation?, [PCMAudioFrame]) = withLockedState {
            switch outputFormat {
            case .realtimeStreaming:
                return (continuation, realtimeConverter.convert(frame))
            case .whisperTranscription:
                return (continuation, [WhisperAudioFormatConverter.convert(frame)])
            }
        }
        for chunk in chunksToYield { cont?.yield(chunk) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let shouldRestart = withLockedState { () -> Bool in
            guard activeStream === stream else { return false }
            activeStream = nil
            guard continuation != nil, !didAttemptRestart, activeFilter != nil else { return false }
            didAttemptRestart = true
            return true
        }
        guard shouldRestart else {
            finishStreams()
            return
        }
        let reason = String(describing: error)
        Task { [self] in
            try? await Task.sleep(for: Self.restartDelay)
            await restartCapture(reason: reason)
        }
    }

    private func restartCapture(reason: String) async {
        let parts = withLockedState { () -> (SCContentFilter, SCStreamConfiguration)? in
            guard continuation != nil, let activeFilter, let activeConfiguration else { return nil }
            return (activeFilter, activeConfiguration)
        }
        guard let (filter, configuration) = parts else { return }
        let restarted = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try restarted.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
            try await restarted.startCapture()
        } catch {
            finishStreams()
            return
        }
        let noticeTarget = withLockedState { () -> AsyncStream<CaptureNotice>.Continuation?? in
            guard continuation != nil else { return .none }
            activeStream = restarted
            realtimeConverter = RealtimeAudioFormatConverter()
            return .some(noticeContinuation)
        }
        guard let noticeTarget else {
            try? await restarted.stopCapture()
            return
        }
        noticeTarget?.yield(.systemCaptureRestarted(reason: reason))
    }

    private func finishStreams() {
        let (frames, notices) = withLockedState { () -> (AsyncStream<PCMAudioFrame>.Continuation?, AsyncStream<CaptureNotice>.Continuation?) in
            activeStream = nil
            activeFilter = nil
            activeConfiguration = nil
            let frames = continuation
            let notices = noticeContinuation
            continuation = nil
            noticeContinuation = nil
            return (frames, notices)
        }
        frames?.finish()
        notices?.finish()
    }
}
