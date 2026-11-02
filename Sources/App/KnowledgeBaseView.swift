import Domain
import SwiftUI

struct KnowledgeBaseView: View {
    @Bindable var viewModel: KnowledgeBaseViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(loc("Мой опыт — база знаний для подсказок")).font(.title3)
                Spacer()
                Button(loc("Закрыть")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Text(loc("Включённые заметки подставляются в каждую подсказку Answers (OpenAI и Claude) вместе с профилем. Добавьте резюме, описания проектов, реальные кейсы, свои подходы к архитектуре и AI harness. Пишите только правду — модель опирается на эти факты и не должна их додумывать."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(loc("Импорт файлов (.md, .txt, .pdf)…")) { viewModel.chooseFilesToImport() }
                Button(loc("Добавить заметку")) { viewModel.addEmptyNote() }
                Spacer()
                Text(contextSummary)
                    .font(.caption)
                    .foregroundStyle(viewModel.context.truncatedNoteCount > 0 ? .orange : .secondary)
            }

            ForEach(viewModel.importMessages, id: \.self) { message in
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }

            List {
                if viewModel.notes.isEmpty {
                    Text(loc("Пока пусто. Импортируйте резюме или добавьте заметку."))
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.notes) { note in
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(
                            get: { note.isEnabled },
                            set: { enabled in Task { await viewModel.setEnabled(enabled, for: note) } }
                        ))
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title).font(.body)
                            Text(noteDetails(note))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(note.content.prefix(160) + (note.content.count > 160 ? "…" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button(loc("Изменить")) { viewModel.editingNote = note }
                        Button(loc("Удалить"), role: .destructive) { Task { await viewModel.delete(note) } }
                    }
                    .padding(.vertical, 2)
                }
            }

            Text(loc("Не добавляйте конфиденциальные данные работодателей и чужие персональные данные: включённые заметки отправляются выбранному провайдеру в каждой сессии Answers. Изменения применяются со следующего запуска Answers."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
        .task { await viewModel.load() }
        .sheet(item: $viewModel.editingNote) { note in
            KnowledgeNoteEditor(note: note) { updated in
                Task { await viewModel.save(updated) }
            } onCancel: {
                viewModel.editingNote = nil
            }
        }
    }

    private var contextSummary: String {
        let context = viewModel.context
        var text = loc("В подсказки уходит:") + " \(context.includedNoteCount) " + loc("заметок") + ", ≈\(viewModel.approximateTokens) " + loc("токенов")
        if context.truncatedNoteCount > 0 {
            text += " · " + loc("обрезано по лимиту:") + " \(context.truncatedNoteCount)"
        }
        return text
    }

    private func noteDetails(_ note: KnowledgeNote) -> String {
        var parts = ["\(note.content.count) " + loc("символов")]
        if let source = note.sourceFileName { parts.append(source) }
        if !note.isEnabled { parts.append(loc("выключена — не отправляется")) }
        return parts.joined(separator: " · ")
    }
}

struct KnowledgeNoteEditor: View {
    @State var note: KnowledgeNote
    let onSave: (KnowledgeNote) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(loc("Название"), text: $note.title)
            TextEditor(text: $note.content)
                .font(.system(size: 12))
                .frame(minHeight: 320)
            HStack {
                Spacer()
                Button(loc("Отмена"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(loc("Сохранить")) { onSave(note) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
    }
}
