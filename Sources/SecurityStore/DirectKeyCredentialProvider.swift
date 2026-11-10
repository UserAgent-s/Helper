import Domain

public enum DirectKeyCredentialError: Error, Sendable, Equatable {
    case missingAPIKey
}

public struct DirectKeyCredentialProvider: RealtimeCredentialProviding {
    private let secretStoring: any SecretStoring

    public init(secretStoring: any SecretStoring) {
        self.secretStoring = secretStoring
    }

    public func currentCredential() async throws -> RealtimeCredential {
        guard let apiKey = try secretStoring.retrieveAPIKey(provider: .openAI), !apiKey.isEmpty else {
            throw DirectKeyCredentialError.missingAPIKey
        }
        return RealtimeCredential(apiKey: apiKey)
    }
}
