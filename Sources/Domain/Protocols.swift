import Foundation

public enum BootstrapUnavailableError: Error, Sendable, Equatable {
    case notYetImplemented(String)
}

public protocol SystemAudioCapturing: Sendable {
    func start(scope: SystemAudioScope) async throws -> SystemAudioCaptureStart
    func stop() async
}

public protocol MicrophoneCapturing: Sendable {
    func start(options: MicrophoneCaptureOptions) async throws -> AsyncStream<PCMAudioFrame>
    func stop() async
}

public protocol MeetingAudioRecording: Sendable {
    func start(meetingID: MeetingID) async
    func write(_ frame: PCMAudioFrame) async
    func finish() async
}

public protocol AnswerTriggering: Sendable {
    func events() -> AsyncStream<Void>
}

public protocol LocalTranscribing: Sendable {
    func transcribe(_ frames: [PCMAudioFrame]) async throws -> [TranscribedSegment]
}

public protocol MeetingRepository: Sendable {
    func createMeeting(startedAt: Date, sourceAppBundleID: String?) async throws -> MeetingID
    func appendSegment(_ segment: TranscribedSegment, meetingID: MeetingID, capturedAt: Date?) async throws
    func finish(meetingID: MeetingID, endedAt: Date) async throws
    func reconcileInterruptedMeetings() async throws -> [MeetingID]
    func fetch(meetingID: MeetingID) async throws -> Meeting
    func history(limit: Int, offset: Int) async throws -> [Meeting]
    func search(query: String) async throws -> [Meeting]
    func delete(meetingID: MeetingID) async throws
    func deleteAll() async throws
}

extension MeetingRepository {
    public func appendSegment(_ segment: TranscribedSegment, meetingID: MeetingID) async throws {
        try await appendSegment(segment, meetingID: meetingID, capturedAt: nil)
    }
}

public protocol SessionRepository: Sendable {
    func create(kind: SessionKind, mode: SessionSpanMode, at date: Date) async throws -> AssistantSession
    func resume(sessionID: SessionID, mode: SessionSpanMode, at date: Date) async throws -> SessionSpan
    func closeSpan(id: String, at date: Date, reason: SessionSpanEndReason) async throws
    func finish(sessionID: SessionID, at date: Date) async throws
    func session(id: SessionID) async throws -> AssistantSession?
    func headers(limit: Int, after cursor: SessionCursor?) async throws -> SessionPage
    func detail(sessionID: SessionID) async throws -> SessionDetail?
    func addBookmark(_ bookmark: SessionBookmark) async throws
    func bookmarks(sessionID: SessionID) async throws -> [SessionBookmark]
    func latestCompletedAnswerID(sessionID: SessionID) async throws -> UUID?
    func removeBookmark(id: String) async throws
    func setTitle(sessionID: SessionID, title: String, source: SessionTitleSource) async throws
    func setPinned(sessionID: SessionID, pinned: Bool) async throws
    func purge(olderThan date: Date, excluding active: SessionID?) async throws -> [SessionID]
    func appendUtterance(_ utterance: SessionUtterance, sessionID: SessionID) async throws
    func deleteIfEmpty(sessionID: SessionID) async throws -> Bool
    func setKnowledgeDigest(sessionID: SessionID, digest: String) async throws
    func knowledgeDigest(sessionID: SessionID) async throws -> String?
}

public protocol QuestionAnswerRepository: Sendable {

    func save(_ pair: QuestionAnswerPair) async throws
    func delete(id: UUID) async throws
    func deleteAll() async throws
    func history(limit: Int) async throws -> [QuestionAnswerPair]
    func search(query: String) async throws -> [QuestionAnswerPair]
}

public struct SummaryMarkdownHeaders: Sendable, Equatable {
    public let shortSummary: String
    public let topics: String
    public let decisions: String
    public let actionItems: String
    public let openQuestions: String
    public let risks: String
    public let keyFacts: String
    public let noTimestampFound: String

    public init(
        shortSummary: String,
        topics: String,
        decisions: String,
        actionItems: String,
        openQuestions: String,
        risks: String,
        keyFacts: String,
        noTimestampFound: String
    ) {
        self.shortSummary = shortSummary
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.risks = risks
        self.keyFacts = keyFacts
        self.noTimestampFound = noTimestampFound
    }

    public static let russianDefault = SummaryMarkdownHeaders(
        shortSummary: "Краткое резюме",
        topics: "Темы",
        decisions: "Решения",
        actionItems: "Задачи",
        openQuestions: "Открытые вопросы",
        risks: "Риски",
        keyFacts: "Ключевые факты",
        noTimestampFound: "таймкод не найден"
    )
}

public protocol SummaryGenerating: Sendable {
    func summarize(meetingID: MeetingID, headers: SummaryMarkdownHeaders) async throws -> MeetingSummary
}

public protocol SummaryRepository: Sendable {
    func save(_ summary: MeetingSummary) async throws
    func fetch(meetingID: MeetingID) async throws -> MeetingSummary?
}

public enum SecretProvider: String, Sendable, Hashable, CaseIterable {
    case openAI = "openai"
    case anthropic
}

public protocol SecretStoring: Sendable {
    func store(apiKey: String, provider: SecretProvider) throws
    func retrieveAPIKey(provider: SecretProvider) throws -> String?
    func deleteAPIKey(provider: SecretProvider) throws
}

extension SecretStoring {
    public func store(apiKey: String) throws {
        try store(apiKey: apiKey, provider: .openAI)
    }

    public func retrieveAPIKey() throws -> String? {
        try retrieveAPIKey(provider: .openAI)
    }

    public func deleteAPIKey() throws {
        try deleteAPIKey(provider: .openAI)
    }
}

public struct RealtimeCredential: Sendable, Equatable {
    public let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }
}

public protocol RealtimeCredentialProviding: Sendable {
    func currentCredential() async throws -> RealtimeCredential
}

public protocol LatencyRecording: Sendable {
    func record(_ metric: LatencyMetric) async
}
