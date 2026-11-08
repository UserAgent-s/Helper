import Foundation

public enum BootstrapUnavailableError: Error, Sendable, Equatable {
    case notYetImplemented(String)
}

public protocol SystemAudioCapturing: Sendable {
    func start(targetApplicationBundleID: String?) async throws -> AsyncStream<PCMAudioFrame>
    func stop() async
}

public protocol MicrophoneCapturing: Sendable {
    func start() async throws -> AsyncStream<PCMAudioFrame>
    func stop() async
}

public protocol MeetingAudioRecording: Sendable {
    func start(meetingID: MeetingID) async
    func write(_ frame: PCMAudioFrame) async
    func finish() async
}

public protocol RealtimeAnswering: Sendable {
    func start(instructions: String) async throws
    func appendAudio(_ frame: PCMAudioFrame) async
    func events() -> AsyncStream<RealtimeAnswerEvent>
    func forceResponse() async throws
    func stop() async
}

public protocol AnswerTriggering: Sendable {
    func events() -> AsyncStream<Void>
}

public protocol LocalTranscribing: Sendable {
    func transcribe(_ frames: [PCMAudioFrame]) async throws -> [TranscribedSegment]
}

public protocol MeetingRepository: Sendable {
    func createMeeting(startedAt: Date, sourceAppBundleID: String?) async throws -> MeetingID
    func appendSegment(_ segment: TranscribedSegment, meetingID: MeetingID) async throws
    func finish(meetingID: MeetingID, endedAt: Date) async throws
    func reconcileInterruptedMeetings() async throws -> [MeetingID]
    func fetch(meetingID: MeetingID) async throws -> Meeting
    func history(limit: Int, offset: Int) async throws -> [Meeting]
    func search(query: String) async throws -> [Meeting]
    func delete(meetingID: MeetingID) async throws
    func deleteAll() async throws
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

public protocol SecretStoring: Sendable {
    func store(apiKey: String) throws
    func retrieveAPIKey() throws -> String?
    func deleteAPIKey() throws
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
