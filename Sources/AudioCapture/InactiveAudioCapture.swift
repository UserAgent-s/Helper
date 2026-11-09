import Domain

public struct InactiveSystemAudioCapturing: SystemAudioCapturing {
    public init() {}

    public func start(scope: SystemAudioScope) async throws -> SystemAudioCaptureStart {
        throw BootstrapUnavailableError.notYetImplemented("SystemAudioCapturing подключается на этапе 03")
    }

    public func stop() async {}
}

public struct InactiveMicrophoneCapturing: MicrophoneCapturing {
    public init() {}

    public func start(options: MicrophoneCaptureOptions) async throws -> AsyncStream<PCMAudioFrame> {
        throw BootstrapUnavailableError.notYetImplemented("MicrophoneCapturing подключается на этапе 03")
    }

    public func stop() async {}
}
