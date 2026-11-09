import Foundation

public enum AudioSourceKind: String, Sendable, Hashable, CaseIterable {
    case systemAudio
    case microphone
}

public struct PCMAudioFrame: Sendable, Equatable {
    public let samples: [Int16]
    public let sampleRate: Int
    public let channelCount: Int
    public let capturedAt: Date
    public let source: AudioSourceKind

    public init(samples: [Int16], sampleRate: Int, channelCount: Int, capturedAt: Date, source: AudioSourceKind) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.capturedAt = capturedAt
        self.source = source
    }
}

public enum RealtimeAnswerEvent: Sendable, Equatable {

    case responseStarted(responseID: String, trigger: AnswerTriggerKind)
    case textDelta(responseID: String, text: String)
    case waitingForQuestion
    case completed(responseID: String)

    case cancelled(responseID: String, reason: String)
    case failed(String)
    case questionContext(responseID: String, itemIDs: [String])
    case transcript(TranscriptEvent)
    case transcriptFailed(itemID: String)
}

public enum TranscriptSource: Sendable, Equatable {
    case remote
    case local
}

public struct TranscribedSegment: Sendable, Equatable {
    public let text: String
    public let startMs: Int
    public let endMs: Int
    public let source: TranscriptSource
    public let language: String?
    public let confidence: Double?

    public init(text: String, startMs: Int, endMs: Int, source: TranscriptSource, language: String? = nil, confidence: Double? = nil) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.source = source
        self.language = language
        self.confidence = confidence
    }
}

public struct MeetingID: Sendable, Equatable, Hashable, RawRepresentable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public enum MeetingStatus: Sendable, Equatable {
    case recording
    case completed
    case interrupted
    case failed
}

public struct Meeting: Sendable, Equatable, Identifiable {
    public let id: MeetingID
    public let title: String?
    public let sourceAppBundleID: String?
    public let startedAt: Date
    public let endedAt: Date?
    public let status: MeetingStatus
    public let segments: [TranscribedSegment]

    public init(
        id: MeetingID,
        title: String? = nil,
        sourceAppBundleID: String? = nil,
        startedAt: Date,
        endedAt: Date?,
        status: MeetingStatus,
        segments: [TranscribedSegment]
    ) {
        self.id = id
        self.title = title
        self.sourceAppBundleID = sourceAppBundleID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.segments = segments
    }
}

public enum AnswerTriggerKind: Sendable, Equatable {
    case automatic
    case manual
}

public enum QuestionTranscriptionStatus: Sendable, Equatable {
    case pending
    case completed
    case failed
}

public enum AnswerRecordStatus: Sendable, Equatable {
    case answerStreaming
    case completed
    case cancelled
    case failed
}

public struct QuestionAnswerPair: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let askedAt: Date
    public let sourceAppBundleID: String?
    public var questionText: String?
    public let contextWindowStartedAt: Date
    public let contextWindowDurationMs: Int
    public let triggerKind: AnswerTriggerKind
    public var questionTranscriptionStatus: QuestionTranscriptionStatus
    public var answerText: String
    public let answerModelID: String
    public var questionTranscriptionModelID: String?
    public let responseID: String
    public var speechEndToFirstDeltaMs: Int?
    public var firstDeltaToFirstPaintMs: Int?
    public var responseTotalMs: Int?
    public var usageTokens: Int?
    public var estimatedCostUSD: Double?
    public var status: AnswerRecordStatus

    public init(
        id: UUID = UUID(),
        askedAt: Date,
        sourceAppBundleID: String?,
        questionText: String? = nil,
        contextWindowStartedAt: Date,
        contextWindowDurationMs: Int,
        triggerKind: AnswerTriggerKind,
        questionTranscriptionStatus: QuestionTranscriptionStatus = .pending,
        answerText: String,
        answerModelID: String,
        questionTranscriptionModelID: String? = nil,
        responseID: String,
        speechEndToFirstDeltaMs: Int? = nil,
        firstDeltaToFirstPaintMs: Int? = nil,
        responseTotalMs: Int? = nil,
        usageTokens: Int? = nil,
        estimatedCostUSD: Double? = nil,
        status: AnswerRecordStatus
    ) {
        self.id = id
        self.askedAt = askedAt
        self.sourceAppBundleID = sourceAppBundleID
        self.questionText = questionText
        self.contextWindowStartedAt = contextWindowStartedAt
        self.contextWindowDurationMs = contextWindowDurationMs
        self.triggerKind = triggerKind
        self.questionTranscriptionStatus = questionTranscriptionStatus
        self.answerText = answerText
        self.answerModelID = answerModelID
        self.questionTranscriptionModelID = questionTranscriptionModelID
        self.responseID = responseID
        self.speechEndToFirstDeltaMs = speechEndToFirstDeltaMs
        self.firstDeltaToFirstPaintMs = firstDeltaToFirstPaintMs
        self.responseTotalMs = responseTotalMs
        self.usageTokens = usageTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.status = status
    }
}

public struct MeetingSummary: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let meetingID: MeetingID
    public let modelID: String
    public let schemaVersion: Int
    public let contentJSON: String
    public let renderedMarkdown: String
    public let usageTokens: Int?
    public let estimatedCostUSD: Double?
    public let generatedAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: MeetingID,
        modelID: String,
        schemaVersion: Int = 1,
        contentJSON: String,
        renderedMarkdown: String,
        usageTokens: Int? = nil,
        estimatedCostUSD: Double? = nil,
        generatedAt: Date
    ) {
        self.id = id
        self.meetingID = meetingID
        self.modelID = modelID
        self.schemaVersion = schemaVersion
        self.contentJSON = contentJSON
        self.renderedMarkdown = renderedMarkdown
        self.usageTokens = usageTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.generatedAt = generatedAt
    }
}

public enum LatencyMetric: Sendable, Equatable {
    case speechEndToFirstDeltaMs(Int)
    case firstDeltaToFirstPaintMs(Int)
    case responseTotalMs(Int)
    case modeStopMs(Int)
    case manualTriggerToFirstDeltaMs(Int)
    case contextDurationMs(Int, trigger: AnswerTriggerKind)
    case droppedAudioFrames(Int)
    case duplicatedAudioFrames(Int)
    case reconnectMs(Int)
    case captureCallbackToSendMs(Int)

    public var millisecondValue: Int? {
        switch self {
        case .speechEndToFirstDeltaMs(let value): value
        case .firstDeltaToFirstPaintMs(let value): value
        case .responseTotalMs(let value): value
        case .modeStopMs(let value): value
        case .manualTriggerToFirstDeltaMs(let value): value
        case .contextDurationMs(let value, trigger: _): value
        case .droppedAudioFrames: nil
        case .duplicatedAudioFrames: nil
        case .reconnectMs(let value): value
        case .captureCallbackToSendMs(let value): value
        }
    }

    public var kindLabel: String {
        switch self {
        case .speechEndToFirstDeltaMs: "speechEndToFirstDeltaMs"
        case .firstDeltaToFirstPaintMs: "firstDeltaToFirstPaintMs"
        case .responseTotalMs: "responseTotalMs"
        case .modeStopMs: "modeStopMs"
        case .manualTriggerToFirstDeltaMs: "manualTriggerToFirstDeltaMs"
        case .contextDurationMs: "contextDurationMs"
        case .droppedAudioFrames: "droppedAudioFrames"
        case .duplicatedAudioFrames: "duplicatedAudioFrames"
        case .reconnectMs: "reconnectMs"
        case .captureCallbackToSendMs: "captureCallbackToSendMs"
        }
    }
}
