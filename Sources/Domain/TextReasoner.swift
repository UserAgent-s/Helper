public struct TextReasoningRequest: Sendable, Equatable {
    public let system: String
    public let prompt: String
    public let maxOutputTokens: Int?

    public init(system: String, prompt: String, maxOutputTokens: Int? = nil) {
        self.system = system
        self.prompt = prompt
        self.maxOutputTokens = maxOutputTokens
    }
}

public protocol TextReasoner: Sendable {
    var capabilities: ProviderCapabilities { get }
    var modelID: String { get }
    func stream(_ request: TextReasoningRequest) -> AsyncThrowingStream<String, any Error>
}
