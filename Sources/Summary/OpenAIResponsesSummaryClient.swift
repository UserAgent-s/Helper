import Domain
import Foundation

public enum SummaryGeneratingError: Error, Sendable, Equatable {
    case notAuthenticated
    case meetingNotCompleted
    case emptyTranscript
    case invalidModelResponse
}

public actor OpenAIResponsesSummaryClient: SummaryGenerating {
    private let secretStoring: any SecretStoring
    private let meetingRepository: any MeetingRepository
    private let transport: any ResponsesAPITransport
    private let modelID: String
    private let maxCharactersPerChunk: Int

    public init(
        secretStoring: any SecretStoring,
        meetingRepository: any MeetingRepository,
        transport: any ResponsesAPITransport = URLSessionResponsesAPITransport(),
        modelID: String = SummaryModelCatalog.defaultModelID,
        maxCharactersPerChunk: Int = 24_000
    ) {
        self.secretStoring = secretStoring
        self.meetingRepository = meetingRepository
        self.transport = transport
        self.modelID = modelID
        self.maxCharactersPerChunk = maxCharactersPerChunk
    }

    public func summarize(meetingID: MeetingID, headers: SummaryMarkdownHeaders) async throws -> MeetingSummary {
        guard let apiKey = try secretStoring.retrieveAPIKey(), !apiKey.isEmpty else {
            throw SummaryGeneratingError.notAuthenticated
        }

        let meeting = try await meetingRepository.fetch(meetingID: meetingID)
        guard meeting.status == .completed else {
            throw SummaryGeneratingError.meetingNotCompleted
        }
        guard !meeting.segments.isEmpty else {
            throw SummaryGeneratingError.emptyTranscript
        }

        let chunks = TranscriptChunker.chunk(meeting.segments, maxCharactersPerChunk: maxCharactersPerChunk)
        try Task.checkCancellation()

        var inputTokens = 0
        var outputTokens = 0
        let content: SummaryContent

        if chunks.count <= 1 {
            let result = try await requestStructuredSummary(
                inputText: TranscriptFormatter.renderMarkdown(meeting.segments),
                instructions: SummaryPromptTemplate.instructions,
                apiKey: apiKey
            )
            content = result.content
            inputTokens += result.inputTokens
            outputTokens += result.outputTokens
        } else {
            var partials: [SummaryContent] = []
            for chunk in chunks {
                try Task.checkCancellation()
                let result = try await requestStructuredSummary(
                    inputText: TranscriptFormatter.renderMarkdown(chunk),
                    instructions: SummaryPromptTemplate.partialChunkInstructions,
                    apiKey: apiKey
                )
                partials.append(result.content)
                inputTokens += result.inputTokens
                outputTokens += result.outputTokens
            }
            try Task.checkCancellation()
            let mergeInput = try Self.encodePartialsAsInput(partials)
            let merged = try await requestStructuredSummary(
                inputText: mergeInput,
                instructions: SummaryPromptTemplate.mergeInstructions,
                apiKey: apiKey
            )
            content = merged.content
            inputTokens += merged.inputTokens
            outputTokens += merged.outputTokens
        }

        let contentJSONData = try Self.encoder.encode(content)
        let contentJSONString = String(data: contentJSONData, encoding: .utf8) ?? "{}"
        let pricing = SummaryPricingCatalog.byModelID[modelID]
        let costUSD = pricing.map {
            Double(inputTokens) / 1_000_000 * $0.inputCostPerMillionTokensUSD
                + Double(outputTokens) / 1_000_000 * $0.outputCostPerMillionTokensUSD
        }

        return MeetingSummary(
            meetingID: meetingID,
            modelID: modelID,
            schemaVersion: SummaryJSONSchema.version,
            contentJSON: contentJSONString,
            renderedMarkdown: SummaryMarkdownRenderer.render(content, headers: headers),
            usageTokens: inputTokens + outputTokens,
            estimatedCostUSD: costUSD,
            generatedAt: Date()
        )
    }

    private func requestStructuredSummary(
        inputText: String,
        instructions: String,
        apiKey: String
    ) async throws -> (content: SummaryContent, inputTokens: Int, outputTokens: Int) {
        let requestBody = try Self.buildRequestBody(modelID: modelID, instructions: instructions, inputText: inputText)
        let responseData = try await transport.createResponse(requestBody: requestBody, apiKey: apiKey)
        return try Self.parseResponse(responseData)
    }

    private static func buildRequestBody(modelID: String, instructions: String, inputText: String) throws -> Data {
        let requestObject: [String: Any] = [
            "model": modelID,
            "input": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": inputText],
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "meeting_summary",
                    "strict": true,
                    "schema": SummaryJSONSchema.makeJSONSchemaDictionary(),
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: requestObject)
    }

    private static func parseResponse(_ data: Data) throws -> (content: SummaryContent, inputTokens: Int, outputTokens: Int) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummaryGeneratingError.invalidModelResponse
        }

        let usage = root["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int ?? 0
        let outputTokens = usage?["output_tokens"] as? Int ?? 0

        let outputText = try extractOutputText(root)
        guard let outputTextData = outputText.data(using: .utf8) else {
            throw SummaryGeneratingError.invalidModelResponse
        }
        let content = try decoder.decode(SummaryContent.self, from: outputTextData)
        return (content, inputTokens, outputTokens)
    }

    private static func extractOutputText(_ root: [String: Any]) throws -> String {
        if let outputText = root["output_text"] as? String {
            return outputText
        }
        guard let output = root["output"] as? [[String: Any]] else {
            throw SummaryGeneratingError.invalidModelResponse
        }
        for item in output {
            guard let contentItems = item["content"] as? [[String: Any]] else { continue }
            for contentItem in contentItems {
                if let text = contentItem["text"] as? String {
                    return text
                }
            }
        }
        throw SummaryGeneratingError.invalidModelResponse
    }

    private static func encodePartialsAsInput(_ partials: [SummaryContent]) throws -> String {
        let datas = try partials.map { try encoder.encode($0) }
        let strings = datas.map { String(data: $0, encoding: .utf8) ?? "{}" }
        return strings.enumerated().map { index, json in "Часть \(index + 1):\n\(json)" }.joined(separator: "\n\n")
    }

    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
