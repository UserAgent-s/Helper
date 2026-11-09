import Foundation

public struct SessionExportDocument: Sendable, Equatable {
    public let filename: String
    public let markdown: String

    public init(filename: String, markdown: String) {
        self.filename = filename
        self.markdown = markdown
    }
}

public protocol SessionDocumentExporting: Sendable {
    func exportDocument(sessionID: SessionID) async throws -> SessionExportDocument?
}

public actor SessionFinalizer {
    private let repository: any SessionRepository
    private let summaries: (any SummaryGenerating)?
    private let summaryStore: (any SummaryRepository)?
    private let isAutoSummaryEnabled: @Sendable () -> Bool
    private let timeZone: TimeZone
    private let headers: SummaryMarkdownHeaders

    private var pending: [SessionID: Task<Void, Never>] = [:]
    public private(set) var titledCount = 0
    public private(set) var summarySuccessCount = 0
    public private(set) var summaryFailureCount = 0

    public init(
        repository: any SessionRepository,
        summaries: (any SummaryGenerating)? = nil,
        summaryStore: (any SummaryRepository)? = nil,
        isAutoSummaryEnabled: @escaping @Sendable () -> Bool = { false },
        timeZone: TimeZone = .current,
        headers: SummaryMarkdownHeaders = .russianDefault
    ) {
        self.repository = repository
        self.summaries = summaries
        self.summaryStore = summaryStore
        self.isAutoSummaryEnabled = isAutoSummaryEnabled
        self.timeZone = timeZone
        self.headers = headers
    }

    public func finalize(sessionID: SessionID) async {
        guard let detail = try? await repository.detail(sessionID: sessionID) else { return }
        let session = detail.session
        if session.titleSource == nil || session.titleSource == .heuristic {
            let title = SessionTitleHeuristic.title(for: detail, timeZone: timeZone)
            if title != session.title || session.titleSource != .heuristic {
                if (try? await repository.setTitle(sessionID: sessionID, title: title, source: .heuristic)) != nil {
                    titledCount += 1
                }
            }
        }
        guard isAutoSummaryEnabled(), let summaries, let summaryStore, pending[sessionID] == nil else { return }
        guard !detail.utterances.isEmpty else { return }
        let headers = self.headers
        pending[sessionID] = Task { [weak self] in
            do {
                let summary = try await summaries.summarize(meetingID: sessionID, headers: headers)
                try await summaryStore.save(summary)
                await self?.summaryFinished(sessionID, succeeded: true)
            } catch {
                await self?.summaryFinished(sessionID, succeeded: false)
            }
        }
    }

    public func waitForPendingSummaries() async {
        while let task = pending.values.first {
            await task.value
        }
    }

    private func summaryFinished(_ sessionID: SessionID, succeeded: Bool) {
        pending[sessionID] = nil
        if succeeded { summarySuccessCount += 1 } else { summaryFailureCount += 1 }
    }
}
