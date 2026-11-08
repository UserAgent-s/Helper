import Domain
import Foundation
import Observation
import Summary

@MainActor
@Observable
final class MeetingDetailViewModel: Identifiable {
    nonisolated var id: MeetingID { meeting.id }
    let meeting: Meeting
    private let summaryGenerating: any SummaryGenerating
    private let summaryRepository: any SummaryRepository

    private(set) var summary: MeetingSummary?
    private(set) var isGenerating = false
    private(set) var lastError: String?
    var isConfirmingGenerate = false
    let costEstimate: SummaryCostEstimate

    init(meeting: Meeting, summaryGenerating: any SummaryGenerating, summaryRepository: any SummaryRepository) {
        self.meeting = meeting
        self.summaryGenerating = summaryGenerating
        self.summaryRepository = summaryRepository
        costEstimate = CostEstimator.estimate(
            transcriptCharacterCount: TranscriptFormatter.renderMarkdown(meeting.segments).count,
            modelID: SummaryModelCatalog.defaultModelID
        )
    }

    func loadExistingSummary() async {
        summary = try? await summaryRepository.fetch(meetingID: meeting.id)
    }

    func requestGenerate() {
        isConfirmingGenerate = true
    }

    func confirmGenerate() async {
        isConfirmingGenerate = false
        isGenerating = true
        defer { isGenerating = false }
        do {
            let headers = SummaryMarkdownHeaders(
                shortSummary: loc("Краткое резюме"),
                topics: loc("Темы"),
                decisions: loc("Решения"),
                actionItems: loc("Задачи"),
                openQuestions: loc("Открытые вопросы"),
                risks: loc("Риски"),
                keyFacts: loc("Ключевые факты"),
                noTimestampFound: loc("таймкод не найден")
            )
            let result = try await summaryGenerating.summarize(meetingID: meeting.id, headers: headers)
            try await summaryRepository.save(result)
            summary = result
            lastError = nil
        } catch {
            lastError = loc("Не удалось создать саммари:") + " \(error)"
        }
    }

    var transcriptMarkdown: String {
        TranscriptFormatter.renderMarkdown(meeting.segments, localSpeakerLabel: loc("Я"), remoteSpeakerLabel: loc("Участники"))
    }

    var transcriptJSON: Data? {
        try? TranscriptFormatter.renderJSON(meeting.segments, localSpeakerLabel: loc("Я"), remoteSpeakerLabel: loc("Участники"))
    }

    var transcriptAndSummaryMarkdown: String? {
        guard let summary else { return nil }
        return transcriptMarkdown + "\n\n---\n\n" + summary.renderedMarkdown
    }

    var summaryJSON: Data? {
        summary?.contentJSON.data(using: .utf8)
    }
}
