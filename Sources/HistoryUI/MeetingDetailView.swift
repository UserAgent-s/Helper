import AppKit
import SwiftUI

struct MeetingDetailView: View {
    @Bindable var viewModel: MeetingDetailViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Button(loc("Закрыть")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top])

            ScrollView {
                Text(viewModel.transcriptMarkdown)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            if let summary = viewModel.summary {
                Divider()
                ScrollView {
                    Text(summary.renderedMarkdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }

            if let error = viewModel.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button(viewModel.isGenerating ? loc("Создаём…") : loc("Создать саммари")) {
                    viewModel.requestGenerate()
                }
                .disabled(viewModel.isGenerating)

                Spacer()

                Menu(loc("Экспорт")) {
                    Button(loc("Transcript (Markdown)")) { export(text: viewModel.transcriptMarkdown, suggestedName: "transcript.md") }
                    Button(loc("Transcript (JSON)")) {
                        if let data = viewModel.transcriptJSON { export(data: data, suggestedName: "transcript.json") }
                    }
                    Button(loc("Transcript + саммари (Markdown)")) {
                        if let text = viewModel.transcriptAndSummaryMarkdown { export(text: text, suggestedName: "meeting-with-summary.md") }
                    }
                    .disabled(viewModel.summary == nil)
                    Button(loc("Саммари (JSON)")) {
                        if let data = viewModel.summaryJSON { export(data: data, suggestedName: "summary.json") }
                    }
                    .disabled(viewModel.summary == nil)
                }
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 480)
        .task { await viewModel.loadExistingSummary() }
        .confirmationDialog(
            loc("Транскрипт") + " (~\(viewModel.costEstimate.estimatedInputTokens) " + loc("токенов, ориентировочно") + " $\(String(format: "%.3f", viewModel.costEstimate.estimatedCostUSD))) " + loc("будет отправлен во внешний API. Продолжить?"),
            isPresented: $viewModel.isConfirmingGenerate,
            titleVisibility: .visible
        ) {
            Button(loc("Отправить и создать саммари")) {
                Task { await viewModel.confirmGenerate() }
            }
            Button(loc("Отмена"), role: .cancel) {}
        }
    }

    private func export(text: String, suggestedName: String) {
        export(data: Data(text.utf8), suggestedName: suggestedName)
    }

    private func export(data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
}
