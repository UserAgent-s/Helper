import CoreMedia
import Domain
import ScreenCaptureKit

public final class ScreenCaptureKitSystemAudioCapturing: NSObject, SystemAudioCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let outputFormat: AudioCaptureOutputFormat
    private let permissions: any PermissionsChecking
    private let captureQueue = DispatchQueue(label: "com.local.UserAgent057.audiocapture.system")
    private let stateLock = NSLock()

    private var activeStream: SCStream?
    private var continuation: AsyncStream<PCMAudioFrame>.Continuation?
    private var realtimeConverter = RealtimeAudioFormatConverter()

    public init(outputFormat: AudioCaptureOutputFormat, permissions: any PermissionsChecking = SystemPermissionsChecker()) {
        self.outputFormat = outputFormat
        self.permissions = permissions
        super.init()
    }

    private func withLockedState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    public func start(targetApplicationBundleID: String?) async throws -> AsyncStream<PCMAudioFrame> {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            let preflightStatus = await permissions.status(for: .screenRecording)
            if preflightStatus != .authorized {
                throw AudioCaptureError.permissionDenied(.screenRecording)
            }
            throw error
        }
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayAvailable
        }

        let filter: SCContentFilter
        if let targetApplicationBundleID {
            guard let app = content.applications.first(where: { $0.bundleIdentifier == targetApplicationBundleID }) else {
                throw AudioCaptureError.targetApplicationNotFound(targetApplicationBundleID)
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = outputFormat.targetSampleRate
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)

        let (audioStream, audioContinuation) = AsyncStream<PCMAudioFrame>.makeStream()
        withLockedState {
            activeStream = newStream
            continuation = audioContinuation
            realtimeConverter = RealtimeAudioFormatConverter()
        }

        try await newStream.startCapture()
        return audioStream
    }

    public func stop() async {
        let streamToStop = withLockedState { () -> SCStream? in
            let streamToStop = activeStream
            activeStream = nil
            continuation?.finish()
            continuation = nil
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
        let cont = withLockedState { () -> AsyncStream<PCMAudioFrame>.Continuation? in
            activeStream = nil
            let cont = continuation
            continuation = nil
            return cont
        }
        cont?.finish()
    }
}
