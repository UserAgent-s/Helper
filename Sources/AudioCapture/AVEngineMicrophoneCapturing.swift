import AVFAudio
import Domain
import Foundation

public final class AVEngineMicrophoneCapturing: NSObject, MicrophoneCapturing, @unchecked Sendable {
    private let permissions: any PermissionsChecking
    private let stateLock = NSLock()
    private let reconfigurations = AsyncBroadcaster<AudioDeviceChange>()
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<PCMAudioFrame>.Continuation?
    private var configurationObserver: NSObjectProtocol?

    public init(permissions: any PermissionsChecking = SystemPermissionsChecker()) {
        self.permissions = permissions
        super.init()
    }

    private func withLockedState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    static let minimalDucking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)

    public func engineReconfigurations() -> AsyncStream<AudioDeviceChange> {
        reconfigurations.subscribe("microphoneEngine")
    }

    public func start(options: MicrophoneCaptureOptions) async throws -> AsyncStream<PCMAudioFrame> {
        let status = await permissions.request(.microphone)
        guard status == .authorized else {
            throw AudioCaptureError.permissionDenied(.microphone)
        }

        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode
        if options.voiceProcessing {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                throw AudioCaptureError.voiceProcessingUnavailable(error.localizedDescription)
            }
            inputNode.voiceProcessingOtherAudioDuckingConfiguration = Self.minimalDucking
        }
        if let uid = options.deviceUID, var deviceID = CoreAudioDeviceCatalog.deviceID(forUID: uid), let unit = inputNode.audioUnit {
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                throw AudioCaptureError.microphoneDeviceUnavailable(uid)
            }
        }

        let (audioStream, audioContinuation) = AsyncStream<PCMAudioFrame>.makeStream()
        withLockedState {
            engine = newEngine
            continuation = audioContinuation
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let frame = Self.makeFrame(from: buffer, source: .microphone) else { return }
            let converted = MicrophoneFrameConverter.convert(frame, options: options)
            let cont = self.withLockedState { self.continuation }
            cont?.yield(converted)
        }

        let reconfigurations = self.reconfigurations
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: newEngine,
            queue: nil
        ) { _ in
            reconfigurations.yield(.microphoneEngineReconfigured)
        }
        withLockedState { configurationObserver = observer }

        do {
            newEngine.prepare()
            try newEngine.start()
        } catch {
            await stop()
            throw error
        }
        return audioStream
    }

    public func stop() async {
        let (engineToStop, observer, cont) = withLockedState { () -> (AVAudioEngine?, NSObjectProtocol?, AsyncStream<PCMAudioFrame>.Continuation?) in
            let result = (engine, configurationObserver, continuation)
            engine = nil
            configurationObserver = nil
            continuation = nil
            return result
        }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if let engineToStop {
            engineToStop.inputNode.removeTap(onBus: 0)
            if engineToStop.isRunning {
                engineToStop.stop()
            }
        }
        cont?.finish()
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
