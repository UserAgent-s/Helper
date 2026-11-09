public enum Speaker: String, Sendable, Equatable, Hashable {
    case them
    case me
}

public struct TranscriptEvent: Sendable, Equatable {
    public let speaker: Speaker
    public let itemID: String
    public let text: String
    public let language: String?
    public let isFinal: Bool

    public init(speaker: Speaker, itemID: String, text: String, language: String? = nil, isFinal: Bool) {
        self.speaker = speaker
        self.itemID = itemID
        self.text = text
        self.language = language
        self.isFinal = isFinal
    }
}
