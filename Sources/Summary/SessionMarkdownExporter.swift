import Domain
import Foundation

public struct SessionMarkdownExporter: SessionDocumentExporting {
    private let repository: any SessionRepository
    private let summaries: (any SummaryRepository)?
    private let labels: SessionMarkdownLabels
    private let timeZone: TimeZone

    public init(
        repository: any SessionRepository,
        summaries: (any SummaryRepository)? = nil,
        labels: SessionMarkdownLabels = .russian,
        timeZone: TimeZone = .current
    ) {
        self.repository = repository
        self.summaries = summaries
        self.labels = labels
        self.timeZone = timeZone
    }

    public func exportDocument(sessionID: SessionID) async throws -> SessionExportDocument? {
        guard let detail = try await repository.detail(sessionID: sessionID) else { return nil }
        let summary = try? await summaries?.fetch(meetingID: sessionID)
        let markdown = SessionMarkdownRenderer.render(detail, summary: summary ?? nil, labels: labels, timeZone: timeZone)
        return SessionExportDocument(filename: Self.filename(startedAt: detail.session.startedAt, timeZone: timeZone), markdown: markdown)
    }

    public static func filename(startedAt: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: startedAt)
        return String(format: "UserAgent057-%04d-%02d-%02d-%02d%02d.md", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }
}
