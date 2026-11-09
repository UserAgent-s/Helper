import Domain
import Foundation
import Observation

struct SessionHistoryRow: Identifiable, Equatable {
    let id: SessionID
    let title: String?
    let startedAt: Date
    let questionCount: Int?
    let starCount: Int?
    let snippets: [String]

    init(header: SessionHeader) {
        id = header.id
        title = header.title
        startedAt = header.startedAt
        questionCount = header.questionAnswerCount
        starCount = header.starCount
        snippets = []
    }

    init(result: SessionSearchResult) {
        id = result.sessionID
        title = result.title
        startedAt = result.startedAt
        questionCount = nil
        starCount = nil
        snippets = result.hits.map(\.snippet)
    }
}

@MainActor
@Observable
final class SessionDetailViewModel: Identifiable {
    let sessionID: SessionID
    private let history: any SessionHistoryQuerying
    private(set) var detail: SessionHistoryDetail?
    private(set) var lastError: String?
    private(set) var isLoading = false

    nonisolated var id: UUID { sessionID.rawValue }

    init(sessionID: SessionID, history: any SessionHistoryQuerying) {
        self.sessionID = sessionID
        self.history = history
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await history.detail(sessionID: sessionID)
            lastError = detail == nil ? loc("Сессия не найдена.") : nil
        } catch {
            lastError = loc("Не удалось загрузить сессию:") + " \(error)"
        }
    }

    func speakerLabel(_ speaker: Speaker) -> String {
        speaker == .me ? loc("Я") : loc("Собеседник")
    }

    func offset(_ date: Date?) -> String {
        guard let date, let start = detail?.session.startedAt else { return "" }
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return String(format: "+%02d:%02d", seconds / 60, seconds % 60)
    }
}
