import Foundation

public struct AnswerState: Codable, Sendable, Equatable {
    public let answerId: String
    public let trigger: WireTrigger
    public let status: WireAnswerStatus
    public let text: String
    public let points: [AnswerPoint]

    public init(answerId: String, trigger: WireTrigger, status: WireAnswerStatus, text: String, points: [AnswerPoint] = []) {
        self.answerId = answerId
        self.trigger = trigger
        self.status = status
        self.text = text
        self.points = points
    }
}

public struct StateSnapshot: Codable, Sendable, Equatable {
    public let mode: ModeInfo
    public let answer: AnswerState?
    public let transcript: [TranscriptLine]
    public let levels: [LevelInfo]
    public let notices: [NoticeInfo]
    public let session: SessionInfo?
    public let overlayEnabled: Bool
    public let capabilities: [String]

    public init(
        mode: ModeInfo,
        answer: AnswerState? = nil,
        transcript: [TranscriptLine] = [],
        levels: [LevelInfo] = [],
        notices: [NoticeInfo] = [],
        session: SessionInfo? = nil,
        overlayEnabled: Bool = true,
        capabilities: [String] = []
    ) {
        self.mode = mode
        self.answer = answer
        self.transcript = transcript
        self.levels = levels
        self.notices = notices
        self.session = session
        self.overlayEnabled = overlayEnabled
        self.capabilities = capabilities
    }
}
