import Domain
import Foundation
import Observation
import Summary

enum HistoryTab: Sendable {
    case questionsAndAnswers
    case meetings
}

@MainActor
@Observable
final class HistoryViewModel {
    private let questionAnswerRepository: any QuestionAnswerRepository
    private let meetingRepository: any MeetingRepository
    private let summaryGenerating: any SummaryGenerating
    private let summaryRepository: any SummaryRepository

    var selectedTab: HistoryTab = .questionsAndAnswers
    var searchText: String = ""
    private(set) var qaEntries: [QuestionAnswerPair] = []
    private(set) var meetings: [Meeting] = []
    private(set) var lastError: String?
    var isConfirmingClearAll = false
    var selectedMeetingDetail: MeetingDetailViewModel?

    init(
        questionAnswerRepository: any QuestionAnswerRepository,
        meetingRepository: any MeetingRepository,
        summaryGenerating: any SummaryGenerating,
        summaryRepository: any SummaryRepository
    ) {
        self.questionAnswerRepository = questionAnswerRepository
        self.meetingRepository = meetingRepository
        self.summaryGenerating = summaryGenerating
        self.summaryRepository = summaryRepository
    }

    func openDetail(for meeting: Meeting) {
        selectedMeetingDetail = MeetingDetailViewModel(
            meeting: meeting,
            summaryGenerating: summaryGenerating,
            summaryRepository: summaryRepository
        )
    }

    func load() async {
        do {
            qaEntries = searchText.isEmpty
                ? try await questionAnswerRepository.history(limit: 200)
                : try await questionAnswerRepository.search(query: searchText)
            meetings = searchText.isEmpty
                ? try await meetingRepository.history(limit: 200, offset: 0)
                : try await meetingRepository.search(query: searchText)
            lastError = nil
        } catch {
            lastError = loc("Не удалось загрузить историю:") + " \(error)"
        }
    }

    func deleteQuestionAnswer(_ pair: QuestionAnswerPair) async {
        do {
            try await questionAnswerRepository.delete(id: pair.id)
            await load()
        } catch {
            lastError = loc("Не удалось удалить запись:") + " \(error)"
        }
    }

    func deleteMeeting(_ meeting: Meeting) async {
        do {
            try await meetingRepository.delete(meetingID: meeting.id)
            await load()
        } catch {
            lastError = loc("Не удалось удалить встречу:") + " \(error)"
        }
    }

    func confirmClearAll() async {
        do {
            switch selectedTab {
            case .questionsAndAnswers:
                try await questionAnswerRepository.deleteAll()
            case .meetings:
                try await meetingRepository.deleteAll()
            }
            isConfirmingClearAll = false
            await load()
        } catch {
            lastError = loc("Не удалось очистить историю:") + " \(error)"
        }
    }

    func speakerLabel(for segment: TranscribedSegment) -> String {
        segment.source == .local ? loc("Я") : loc("Участники")
    }

    func duration(of meeting: Meeting) -> String {
        guard let endedAt = meeting.endedAt else { return loc("в процессе") }
        let seconds = Int(endedAt.timeIntervalSince(meeting.startedAt))
        return "\(seconds / 60) " + loc("мин") + " \(seconds % 60) " + loc("с")
    }
}
