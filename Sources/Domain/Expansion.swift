import Foundation

public enum ExpansionFormat: String, Sendable, Equatable, CaseIterable, Codable {
    case structured, short, steps, code, star
}

public enum ExpansionLanguage: String, Sendable, Equatable, CaseIterable, Codable {
    case auto, ru, en, both
}

public enum ExpansionModelChoice: String, Sendable, Equatable, CaseIterable, Codable {
    case sonnet, opus
}

public enum ExpansionSource: Sendable, Equatable {
    case point(answerID: String, pointID: String, pointText: String, answerText: String)
    case answer(answerID: String, answerText: String)
    case freeText(String)

    public var kind: String {
        switch self {
        case .point: "point"
        case .answer: "answer"
        case .freeText: "free_text"
        }
    }

    public var answerID: String? {
        switch self {
        case .point(let id, _, _, _), .answer(let id, _): id
        case .freeText: nil
        }
    }

    public var pointID: String? {
        if case .point(_, let id, _, _) = self { return id }
        return nil
    }

    public var focusText: String {
        switch self {
        case .point(_, _, let text, _): text
        case .answer(_, let text): text
        case .freeText(let text): text
        }
    }
}

public struct ExpansionRequest: Sendable, Equatable {
    public var source: ExpansionSource
    public var format: ExpansionFormat
    public var language: ExpansionLanguage
    public var model: ExpansionModelChoice?
    public var transcriptTail: [String]
    public var screenText: String?
    public var note: String?

    public init(source: ExpansionSource, format: ExpansionFormat = .structured, language: ExpansionLanguage = .auto, model: ExpansionModelChoice? = nil, transcriptTail: [String] = [], screenText: String? = nil, note: String? = nil) {
        self.note = note
        self.source = source
        self.format = format
        self.language = language
        self.model = model
        self.transcriptTail = transcriptTail
        self.screenText = screenText
    }
}

public enum ExpansionOutcome: String, Sendable, Equatable {
    case completed
    case truncated
    case refused
    case failed
    case cancelled
}

public enum ExpansionEvent: Sendable, Equatable {
    case started(expansionID: String, modelID: String, format: ExpansionFormat, language: ExpansionLanguage)
    case delta(expansionID: String, offset: Int, text: String)
    case finished(expansionID: String, outcome: ExpansionOutcome, errorCode: String?)
}

public enum ExpansionRejection: Error, Sendable, Equatable {
    case unavailable
    case unknownExpansion
    case busy
    case emptyQuestion
}

public protocol ExpansionRequesting: Sendable {
    func isAvailable() async -> Bool
    func expand(_ request: ExpansionRequest) async throws -> AsyncStream<ExpansionEvent>
    func followUp(expansionID: String, question: String) async throws -> AsyncStream<ExpansionEvent>
    func cancel(expansionID: String) async
}

public struct DeepExpansionRecord: Sendable, Equatable {
    public let id: String
    public let sessionID: SessionID
    public var questionAnswerID: UUID?
    public let parentID: String?
    public let requestedAt: Date
    public let modelID: String
    public var status: String
    public var text: String
    public let sourceKind: String
    public let pointID: String?
    public let sourceText: String
    public let format: String
    public let language: String
    public var ttftMs: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var estimatedCostUSD: Double?
    public var stopReason: String?

    public init(id: String, sessionID: SessionID, questionAnswerID: UUID?, parentID: String?, requestedAt: Date, modelID: String, status: String, text: String, sourceKind: String, pointID: String?, sourceText: String, format: String, language: String, ttftMs: Int? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil, estimatedCostUSD: Double? = nil, stopReason: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.questionAnswerID = questionAnswerID
        self.parentID = parentID
        self.requestedAt = requestedAt
        self.modelID = modelID
        self.status = status
        self.text = text
        self.sourceKind = sourceKind
        self.pointID = pointID
        self.sourceText = sourceText
        self.format = format
        self.language = language
        self.ttftMs = ttftMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.stopReason = stopReason
    }
}

public protocol DeepExpansionStoring: Sendable {
    func saveExpansion(_ record: DeepExpansionRecord) async throws
    func expansionRecord(id: String) async throws -> DeepExpansionRecord?
    func questionAnswerID(responseID: String) async throws -> UUID?
}
