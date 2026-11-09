import Domain
import SwiftUI

struct SessionDetailView: View {
    @Bindable var viewModel: SessionDetailViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(viewModel.detail?.session.title ?? loc("Сессия"))
                    .font(.headline)
                    .accessibilityIdentifier("history.sessionDetail.title")
                Spacer()
                Button(loc("Закрыть")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            if let error = viewModel.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if let detail = viewModel.detail {
                content(detail)
            } else if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .accessibilityIdentifier("history.sessionDetail")
        .task { await viewModel.load() }
    }

    private func content(_ detail: SessionHistoryDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(detail.session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let summary = detail.summary {
                    section(loc("Саммари")) {
                        Text(summary.renderedMarkdown)
                            .textSelection(.enabled)
                    }
                }

                if !detail.detail.bookmarks.isEmpty {
                    section(loc("Отмеченное")) {
                        ForEach(detail.detail.bookmarks) { bookmark in
                            Text("\(bookmark.kind == .star ? "★" : "⚑") \(viewModel.offset(bookmark.markedAt)) \(bookmark.note ?? "")")
                        }
                    }
                }

                if !detail.questions.isEmpty {
                    section(loc("Вопросы и ответы")) {
                        ForEach(detail.questions) { question in
                            questionView(question)
                        }
                    }
                }

                if !detail.unattachedExpansions.isEmpty {
                    section(loc("Раскрытия")) {
                        ForEach(detail.unattachedExpansions) { expansion in
                            Text(expansion.text).textSelection(.enabled)
                        }
                    }
                }

                if !detail.detail.utterances.isEmpty {
                    section(loc("Транскрипт")) {
                        ForEach(detail.detail.utterances) { utterance in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(viewModel.offset(utterance.capturedAt)) \(viewModel.speakerLabel(utterance.speaker))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(utterance.text).textSelection(.enabled)
                                if let translation = utterance.translationText {
                                    Text(translation)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !detail.detail.screenContexts.isEmpty {
                    section(loc("Тексты экрана")) {
                        ForEach(detail.detail.screenContexts) { screen in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(viewModel.offset(screen.capturedAt)) \(screen.application ?? "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(screen.text)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private func questionView(_ question: SessionHistoryQuestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(question.starred ? "★ " : "")\(viewModel.offset(question.pair.askedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(question.pair.questionText ?? loc("Вопрос ещё распознаётся"))
                .font(.subheadline.bold())
            Text(question.pair.answerText)
                .textSelection(.enabled)
            ForEach(question.expansions) { expansion in
                Text(expansion.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.bold())
            content()
        }
    }
}
