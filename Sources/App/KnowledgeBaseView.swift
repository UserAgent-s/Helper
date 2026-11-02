import Domain
import SwiftUI

struct KnowledgeBaseView: View {
    @Bindable var viewModel: KnowledgeBaseViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(loc("Память: профильные области и заметки")).font(.title3)
                Spacer()
                Button(loc("Закрыть")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Text(loc("Активные области задают роль эксперта и правила ответа; их заметки и общие заметки входят в каждую подсказку Answers вместе с профилем. Модель сама выбирает область под вопрос. Неактивные области и выключенные заметки не покидают Mac. Пишите только правду — модель опирается на эти факты."))
                .font(.caption)
                .foregroundStyle(.secondary)

            domainsSection
            folderRow

            HStack {
                Button(loc("Импорт файлов (.md, .txt, .pdf)…")) { viewModel.chooseFilesToImport() }
                Button(loc("Добавить заметку")) { viewModel.addEmptyNote() }
                Picker(loc("В область"), selection: $viewModel.importTargetDomainID) {
                    Text(loc("Общие")).tag(UUID?.none)
                    ForEach(viewModel.domains) { domain in
                        Text(domain.trimmedName).tag(UUID?.some(domain.id))
                    }
                }
                .frame(maxWidth: 260)
                Spacer()
                Text(contextSummary)
                    .font(.caption)
                    .foregroundStyle(viewModel.context.truncatedNoteCount > 0 ? .orange : .secondary)
            }

            ForEach(viewModel.importMessages, id: \.self) { message in
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }

            notesList

            Text(loc("Не добавляйте конфиденциальные данные работодателей и чужие персональные данные: включённые заметки активных областей отправляются выбранному провайдеру в каждой сессии Answers. Изменения применяются со следующего запуска Answers."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 640)
        .task { await viewModel.load() }
        .sheet(item: $viewModel.editingNote) { note in
            KnowledgeNoteEditor(note: note, domains: viewModel.domains) { updated in
                Task { await viewModel.save(updated) }
            } onCancel: {
                viewModel.editingNote = nil
            }
        }
        .sheet(item: $viewModel.editingDomain) { domain in
            ExpertDomainEditor(domain: domain) { updated in
                Task { await viewModel.save(updated) }
            } onCancel: {
                viewModel.editingDomain = nil
            }
        }
    }

    private var domainsSection: some View {
        GroupBox(loc("Профильные области")) {
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.domains.isEmpty {
                    Text(loc("Областей нет: действует режим «Авто» (backend, system design, behavioral)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.domains) { domain in
                    HStack(alignment: .firstTextBaseline) {
                        Toggle("", isOn: Binding(
                            get: { domain.isActive },
                            set: { active in Task { await viewModel.setActive(active, for: domain) } }
                        ))
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(domain.trimmedName).font(.body)
                            Text(domainDetails(domain))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button(loc("Изменить")) { viewModel.editingDomain = domain }
                        Button(loc("Удалить"), role: .destructive) { Task { await viewModel.delete(domain) } }
                    }
                }
                HStack {
                    Button(loc("Добавить область")) { viewModel.addDomain() }
                    Spacer()
                    Text(loc("Активно:") + " \(viewModel.domains.filter(\.isActive).count)/\(viewModel.domains.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var folderRow: some View {
        GroupBox(loc("Папка знаний")) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(viewModel.folderURL.path)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(loc("Открыть папку")) { viewModel.openFolder() }
                    Button(loc("Синхронизировать")) { Task { await viewModel.syncFolder() } }
                        .disabled(viewModel.isSyncing)
                }
                Text(loc("Файлы .md и .txt в папке становятся заметками автоматически: подпапка — область (создаётся сама), файлы в корне — общие. Сюда можно сохранять результаты исследования из Claude Code. Удалённый файл удаляет свою заметку."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let summary = viewModel.lastSyncSummary {
                    Text(loc("Последняя синхронизация:") + " " + summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notesList: some View {
        List {
            if viewModel.notes.isEmpty {
                Text(loc("Пока пусто. Импортируйте резюме, добавьте заметку или положите файлы в папку знаний."))
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
                    Picker("", selection: Binding(
                        get: { note.domainID },
                        set: { id in Task { await viewModel.assign(note, to: id) } }
                    )) {
                        Text(loc("Общие")).tag(UUID?.none)
                        ForEach(viewModel.domains) { domain in
                            Text(domain.trimmedName).tag(UUID?.some(domain.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .disabled(note.origin == .folder)
                    Button(loc("Изменить")) { viewModel.editingNote = note }
                        .disabled(note.origin == .folder)
                    Button(loc("Удалить"), role: .destructive) { Task { await viewModel.delete(note) } }
                        .disabled(note.origin == .folder)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var contextSummary: String {
        let context = viewModel.context
        var text = loc("В подсказки уходит:") + " \(context.includedNoteCount) " + loc("заметок") + ", ≈\(viewModel.approximateTokens) " + loc("токенов")
        if context.truncatedNoteCount > 0 {
            text += " · " + loc("обрезано по лимиту:") + " \(context.truncatedNoteCount)"
        }
        if context.excludedByInactiveDomainCount > 0 {
            text += " · " + loc("не уходит (область выключена):") + " \(context.excludedByInactiveDomainCount)"
        }
        return text
    }

    private func domainDetails(_ domain: ExpertDomain) -> String {
        var parts = ["\(viewModel.noteCount(for: domain)) " + loc("заметок")]
        let role = domain.role.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty { parts.append(role) }
        if !domain.isActive { parts.append(loc("выключена — не отправляется")) }
        return parts.joined(separator: " · ")
    }

    private func noteDetails(_ note: KnowledgeNote) -> String {
        var parts = ["\(note.content.count) " + loc("символов")]
        if let area = viewModel.domainName(for: note.domainID) { parts.append(loc("область:") + " " + area) }
        if note.origin == .folder { parts.append(loc("из папки знаний")) }
        if let source = note.sourceFileName { parts.append(source) }
        if !note.isEnabled { parts.append(loc("выключена — не отправляется")) }
        return parts.joined(separator: " · ")
    }
}

struct KnowledgeNoteEditor: View {
    @State var note: KnowledgeNote
    let domains: [ExpertDomain]
    let onSave: (KnowledgeNote) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(loc("Название"), text: $note.title)
            Picker(loc("Область"), selection: $note.domainID) {
                Text(loc("Общие")).tag(UUID?.none)
                ForEach(domains) { domain in
                    Text(domain.trimmedName).tag(UUID?.some(domain.id))
                }
            }
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

struct ExpertDomainEditor: View {
    @State var domain: ExpertDomain
    let onSave: (ExpertDomain) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(loc("Название области (совпадает с подпапкой в папке знаний)"), text: $domain.name)
            Text(loc("Роль эксперта: кто отвечает, одним-двумя предложениями"))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $domain.role)
                .font(.system(size: 12))
                .frame(minHeight: 60)
            Text(loc("Правила ответа для этой области: на что опираться, какую структуру держать, чего избегать"))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $domain.guidance)
                .font(.system(size: 12))
                .frame(minHeight: 200)
            Toggle(loc("Активна"), isOn: $domain.isActive)
            HStack {
                Spacer()
                Button(loc("Отмена"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(loc("Сохранить")) { onSave(domain) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(domain.trimmedName.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 460)
    }
}
