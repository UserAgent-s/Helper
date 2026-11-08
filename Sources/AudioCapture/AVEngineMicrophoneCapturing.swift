import AVFAudio
import Domain
import Foundation

public final class AVEngineMicrophoneCapturing: NSObject, MicrophoneCapturing, @unchecked Sendable {
    private let permissions: any PermissionsChecking
    private let engine = AVAudioEngine()
    private let stateLock = NSLock()
    private var continuation: AsyncStream<PCMAudioFrame>.Continuation?
    private var tapInstalled = false

    public init(permissions: any PermissionsChecking = SystemPermissionsChecker()) {
        self.permissions = permissions
        super.init()
    }

    private func withLockedState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    public func start() async throws -> AsyncStream<PCMAudioFrame> {
        let status = await permissions.request(.microphone)
        guard status == .authorized else {
            throw AudioCaptureError.permissionDenied(.microphone)
        }

        let (audioStream, audioContinuation) = AsyncStream<PCMAudioFrame>.makeStream()
        withLockedState { continuation = audioContinuation }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let frame = Self.makeFrame(from: buffer, source: .microphone) else { return }
            let converted = WhisperAudioFormatConverter.convert(frame)
            let cont = self.withLockedState { self.continuation }
            cont?.yield(converted)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()

        return audioStream
    }

    public func stop() async {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        withLockedState {
            continuation?.finish()
            continuation = nil
        }
    }

    private static func makeFrame(from buffer: AVAudioPCMBuffer, source: AudioSourceKind) -> PCMAudioFrame? {
        let format = buffer.format
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return nil }

        var interleaved = [Int16](repeating: 0, count: frameLength * channelCount)

        if let int16Data = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                let channelPointer = int16Data[channel]
                for i in 0..<frameLength {
                    interleaved[i * channelCount + channel] = channelPointer[i]
                }
            }
        } else if let floatData = buffer.floatChannelData {
            for channel in 0..<channelCount {
                let channelPointer = floatData[channel]
                for i in 0..<frameLength {
                    let clamped = max(-1.0, min(1.0, channelPointer[i]))
                    interleaved[i * channelCount + channel] = Int16(clamping: Int(clamped * Float32(Int16.max)))
                }
            }
        } else {
            return nil
        }

        return PCMAudioFrame(samples: interleaved, sampleRate: Int(format.sampleRate), channelCount: channelCount, capturedAt: Date(), source: source)
    }
}
