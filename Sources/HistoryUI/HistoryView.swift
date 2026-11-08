import Domain
import SwiftUI

struct HistoryView: View {
    @Bindable var viewModel: HistoryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(loc("Закрыть")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top])

            Picker(loc("Раздел"), selection: $viewModel.selectedTab) {
                Text(loc("Вопросы и ответы")).tag(HistoryTab.questionsAndAnswers)
                Text(loc("Митинги")).tag(HistoryTab.meetings)
            }
            .pickerStyle(.segmented)
            .padding()

            TextField(loc("Поиск"), text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .onChange(of: viewModel.searchText) {
                    Task { await viewModel.load() }
                }

            if let error = viewModel.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            switch viewModel.selectedTab {
            case .questionsAndAnswers:
                questionAnswerList
            case .meetings:
                meetingList
            }

            Button(loc("Очистить всё"), role: .destructive) {
                viewModel.isConfirmingClearAll = true
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 420)
        .task { await viewModel.load() }
        .sheet(item: $viewModel.selectedMeetingDetail) { detailViewModel in
            MeetingDetailView(viewModel: detailViewModel)
        }
        .confirmationDialog(
            loc("Удалить всю историю без возможности восстановления?"),
            isPresented: $viewModel.isConfirmingClearAll,
            titleVisibility: .visible
        ) {
            Button(loc("Удалить всё"), role: .destructive) {
                Task { await viewModel.confirmClearAll() }
            }
            Button(loc("Отмена"), role: .cancel) {}
        }
    }

    private var questionAnswerList: some View {
        List {
            ForEach(viewModel.qaEntries) { pair in
                VStack(alignment: .leading, spacing: 4) {
                    Text(pair.askedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(pair.questionText ?? loc("Вопрос ещё распознаётся"))
                        .font(.subheadline.bold())
                    Text(pair.answerText)
                        .font(.body)
                }
                .swipeActions {
                    Button(loc("Удалить"), role: .destructive) {
                        Task { await viewModel.deleteQuestionAnswer(pair) }
                    }
                }
            }
        }
    }

    private var meetingList: some View {
        List {
            ForEach(viewModel.meetings) { meeting in
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(loc("Длительность:") + " \(viewModel.duration(of: meeting)) · " + loc("Реплик:") + " \(meeting.segments.count)")
                        .font(.subheadline)
                }
                .contentShape(Rectangle())
                .onTapGesture { viewModel.openDetail(for: meeting) }
                .swipeActions {
                    Button(loc("Удалить"), role: .destructive) {
                        Task { await viewModel.deleteMeeting(meeting) }
                    }
                }
            }
        }
    }
}
