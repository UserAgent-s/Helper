import Foundation

public struct SessionHistoryQuestion: Sendable, Equatable, Identifiable {
    public let pair: QuestionAnswerPair
    public let expansions: [SessionExpansion]
    public let starred: Bool

    public var id: UUID { pair.id }

    public init(pair: QuestionAnswerPair, expansions: [SessionExpansion], starred: Bool) {
        self.pair = pair
        self.expansions = expansions
        self.starred = starred
    }
}

public struct SessionHistoryDetail: Sendable, Equatable {
    public let detail: SessionDetail
    public let summary: MeetingSummary?
    public let questions: [SessionHistoryQuestion]
    public let unattachedExpansions: [SessionExpansion]

    public var session: AssistantSession { detail.session }

    public init(detail: SessionDetail, summary: MeetingSummary?) {
        self.detail = detail
        self.summary = summary
        let pairIDs = Set(detail.questionAnswers.map(\.id))
        let starred = Set(detail.bookmarks.filter { $0.kind == .star }.compactMap(\.questionAnswerID))
        var grouped: [UUID: [SessionExpansion]] = [:]
        var loose: [SessionExpansion] = []
        for expansion in detail.expansions.sorted(by: { $0.requestedAt < $1.requestedAt }) {
            if let owner = expansion.questionAnswerID, pairIDs.contains(owner) {
                grouped[owner, default: []].append(expansion)
            } else {
                loose.append(expansion)
            }
        }
        questions = detail.questionAnswers.sorted { $0.askedAt < $1.askedAt }.map { pair in
            SessionHistoryQuestion(pair: pair, expansions: grouped[pair.id] ?? [], starred: starred.contains(pair.id))
        }
        unattachedExpansions = loose
    }
}

public protocol SessionHistoryQuerying: Sendable {
    func list(limit: Int, after cursor: SessionCursor?) async throws -> SessionPage
    func search(query: String, limit: Int) async throws -> [SessionSearchResult]
    func detail(sessionID: SessionID) async throws -> SessionHistoryDetail?
}

public struct SessionHistoryService: SessionHistoryQuerying {
    public static let maxPageSize = 100

    private let repository: any SessionRepository
    private let searcher: (any SessionSearching)?
    private let summaries: (any SummaryRepository)?

    public init(repository: any SessionRepository, searcher: (any SessionSearching)?, summaries: (any SummaryRepository)?) {
        self.repository = repository
        self.searcher = searcher
        self.summaries = summaries
    }

    public func list(limit: Int, after cursor: SessionCursor?) async throws -> SessionPage {
        try await repository.headers(limit: min(max(limit, 1), Self.maxPageSize), after: cursor)
    }

    public func search(query: String, limit: Int) async throws -> [SessionSearchResult] {
        guard let searcher else { return [] }
        return try await searcher.search(query: query, limit: min(max(limit, 1), Self.maxPageSize))
    }

    public func detail(sessionID: SessionID) async throws -> SessionHistoryDetail? {
        guard let detail = try await repository.detail(sessionID: sessionID) else { return nil }
        let summary = try? await summaries?.fetch(meetingID: sessionID)
        return SessionHistoryDetail(detail: detail, summary: summary ?? nil)
    }
}

extension SessionCursor {
    public var token: String {
        "\(Int64((startedAt.timeIntervalSince1970 * 1000).rounded()))_\(id.rawValue.uuidString)"
    }

    public init?(token: String) {
        let parts = token.split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2, let milliseconds = Int64(parts[0]), let uuid = UUID(uuidString: parts[1]) else { return nil }
        self.init(startedAt: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000), id: SessionID(rawValue: uuid))
    }
}
