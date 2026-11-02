import Foundation

public struct TextAnswerHintExpander: HintExpanding {
    public struct Settings: Sendable, Equatable {
        public let modelID: String
        public let systemInstructions: String
        public let maxOutputTokens: Int
        public let reasoningEffort: String?
        public let useServerSideFallback: Bool

        public init(modelID: String, systemInstructions: String, maxOutputTokens: Int, reasoningEffort: String?, useServerSideFallback: Bool) {
            self.modelID = modelID
            self.systemInstructions = systemInstructions
            self.maxOutputTokens = maxOutputTokens
            self.reasoningEffort = reasoningEffort
            self.useServerSideFallback = useServerSideFallback
        }
    }

    private let generator: any TextAnswerGenerating
    private let settingsProvider: @Sendable () -> Settings

    public init(generator: any TextAnswerGenerating, settingsProvider: @escaping @Sendable () -> Settings) {
        self.generator = generator
        self.settingsProvider = settingsProvider
    }

    public func expand(_ request: HintExpansionRequest) -> AsyncThrowingStream<String, Error> {
        let settings = settingsProvider()
        let textRequest = TextAnswerRequest(
            modelID: settings.modelID,
            systemInstructions: settings.systemInstructions,
            transcript: "",
            priorExchanges: [],
            trigger: .manual,
            maxOutputTokens: settings.maxOutputTokens,
            reasoningEffort: settings.reasoningEffort,
            useServerSideFallback: settings.useServerSideFallback,
            userMessage: AnswerInstructionsBuilder.expansionUserMessage(question: request.question, answer: request.answer)
        )
        let generator = self.generator
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in generator.streamAnswer(textRequest) {
                        if case .textDelta(let delta) = event {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct RoutingHintExpander: HintExpanding {
    private let routes: [AnswerProvider: any HintExpanding]
    private let activeProvider: @Sendable () -> AnswerProvider?

    public init(routes: [AnswerProvider: any HintExpanding], activeProvider: @escaping @Sendable () -> AnswerProvider?) {
        self.routes = routes
        self.activeProvider = activeProvider
    }

    public func expand(_ request: HintExpansionRequest) -> AsyncThrowingStream<String, Error> {
        guard let provider = activeProvider(), let route = routes[provider] else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: AnswerProviderError.unknown("no_expander_for_active_provider"))
            }
        }
        return route.expand(request)
    }
}
