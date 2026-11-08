import Domain

public struct InactiveSystemAudioCapturing: SystemAudioCapturing {
    public init() {}

    public func start(targetApplicationBundleID: String?) async throws -> AsyncStream<PCMAudioFrame> {
        throw BootstrapUnavailableError.notYetImplemented("SystemAudioCapturing подключается на этапе 03")
    }

    public func stop() async {}
}

public struct InactiveMicrophoneCapturing: MicrophoneCapturing {
    public init() {}

    public func start() async throws -> AsyncStream<PCMAudioFrame> {
        throw BootstrapUnavailableError.notYetImplemented("MicrophoneCapturing подключается на этапе 03")
    }

    public func stop() async {}
}
