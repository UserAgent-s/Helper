public enum CaptureNotice: Sendable, Equatable {
    case fellBackToWholeSystem(missingBundleID: String)
    case systemCaptureRestarted(reason: String)
}

public struct SystemAudioCaptureStart: Sendable {
    public let frames: AsyncStream<PCMAudioFrame>
    public let effectiveScope: SystemAudioScope
    public let notice: CaptureNotice?
    public let laterNotices: AsyncStream<CaptureNotice>

    public init(
        frames: AsyncStream<PCMAudioFrame>,
        effectiveScope: SystemAudioScope,
        notice: CaptureNotice? = nil,
        laterNotices: AsyncStream<CaptureNotice> = AsyncStream { $0.finish() }
    ) {
        self.frames = frames
        self.effectiveScope = effectiveScope
        self.notice = notice
        self.laterNotices = laterNotices
    }
}
