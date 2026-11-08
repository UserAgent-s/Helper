public struct ProviderCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let serverVAD = ProviderCapabilities(rawValue: 1 << 0)
    public static let inputTranscription = ProviderCapabilities(rawValue: 1 << 1)
    public static let textInjection = ProviderCapabilities(rawValue: 1 << 2)
    public static let functionCalling = ProviderCapabilities(rawValue: 1 << 3)
    public static let manualResponse = ProviderCapabilities(rawValue: 1 << 4)
    public static let streamingText = ProviderCapabilities(rawValue: 1 << 5)
}

public enum ProviderSeamError: Error, Sendable, Equatable {
    case unsupported(String)
}
