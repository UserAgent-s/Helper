public protocol AudioFormatConverting: Sendable {
    func convert(_ frame: PCMAudioFrame) -> PCMAudioFrame
}

public struct PassthroughAudioFormatConverter: AudioFormatConverting {
    public init() {}

    public func convert(_ frame: PCMAudioFrame) -> PCMAudioFrame {
        frame
    }
}
