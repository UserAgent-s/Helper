import Domain

public enum ProviderKeychainServices {
    public static func service(for provider: AnswerProvider, namespace: String = "com.local.MeetingAssistant") -> String {
        switch provider {
        case .openAIRealtime: "\(namespace).openai"
        case .anthropicClaude: "\(namespace).anthropic"
        }
    }
}
