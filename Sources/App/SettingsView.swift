import AppKit
import Domain
import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(loc("Закрыть")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top])

            settingsForm
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    private var settingsForm: some View {
        Form {
            Section(loc("Язык")) {
                Picker(loc("Язык интерфейса"), selection: Binding(
                    get: { LocalizationCenter.shared.language },
                    set: { LocalizationCenter.shared.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }

            Section(loc("API-ключ OpenAI")) {
                SecureField("sk-…", text: $viewModel.apiKeyInput)
                if viewModel.hasAPIKeyFormatWarning {
                    Text(loc("Формат ключа выглядит некорректным (ожидается sk-…)")).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text(loc("Статус:") + " " + viewModel.apiKeyStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(loc("Сохранить")) { viewModel.saveAPIKey() }
                        .disabled(viewModel.apiKeyInput.isEmpty)
                    Button(loc("Удалить"), role: .destructive) { viewModel.deleteAPIKey() }
                }
            }

            Section(loc("Источник системного звука (answers)")) {
                Picker(loc("Приложение"), selection: $viewModel.preferredAudioSourceBundleID) {
                    Text(loc("Не выбрано")).tag("")
                    if !viewModel.preferredAudioSourceBundleID.isEmpty,
                       !viewModel.runningApplications.contains(where: { $0.bundleID == viewModel.preferredAudioSourceBundleID }) {
                        Text("\(viewModel.preferredAudioSourceBundleID) " + loc("(не запущен)")).tag(viewModel.preferredAudioSourceBundleID)
                    }
                    ForEach(viewModel.runningApplications, id: \.bundleID) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
                .onChange(of: viewModel.preferredAudioSourceBundleID) { viewModel.savePreferredAudioSource() }
                Text(loc("По умолчанию — Google Chrome (для звука встреч в Google Meet и т.п.). AirPods как устройство вывода/ввода настраиваются отдельно в системном меню звука macOS."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(loc("Разрешения")) {
                permissionRow(
                    title: "Screen Recording",
                    status: viewModel.screenRecordingStatus,
                    onRequest: viewModel.requestScreenRecordingAccess,
                    onOpenSettings: viewModel.openScreenRecordingSystemSettings
                )
                permissionRow(
                    title: "Microphone",
                    status: viewModel.microphoneStatus,
                    onRequest: viewModel.requestMicrophoneAccess,
                    onOpenSettings: viewModel.openMicrophoneSystemSettings
                )
                Text(loc("Микрофон нужен только для recording; answers работает без него, если выбран системный источник."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(loc("Длина ответа")) {
                Picker(loc("Длина ответа"), selection: $viewModel.answerLength) {
                    Text(loc("Коротко")).tag(AnswerLength.short)
                    Text(loc("Стандартно")).tag(AnswerLength.standard)
                    Text(loc("Подробно")).tag(AnswerLength.detailed)
                }
                .pickerStyle(.segmented)
                Text(loc("Стандартно и подробно: сначала суть ответа, затем детали вторым абзацем. Изменение применится к следующему ответу."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(loc("Оверлей ответов")) {
                Picker(loc("Стиль оверлея"), selection: $viewModel.overlayStyle) {
                    Text(loc("Прикреплено к вырезу")).tag(OverlayStyle.pinned)
                    Text(loc("Плавающее окно")).tag(OverlayStyle.floating)
                    Text(loc("Во весь экран")).tag(OverlayStyle.fullscreen)
                }
                .pickerStyle(.segmented)
                Picker(loc("Шрифт"), selection: $viewModel.overlayFontFamily) {
                    Text(loc("Обычный")).tag(OverlayFontFamily.sans)
                    Text(loc("С засечками")).tag(OverlayFontFamily.serif)
                    Text(loc("Моноширинный")).tag(OverlayFontFamily.mono)
                }
                .pickerStyle(.segmented)
                Text(loc("«Прикреплено к вырезу» — компактная панель вверху экрана в стиле Dynamic Island. «Во весь экран» — крупный текст на весь дисплей, выход по Esc. Изменение применится к следующему показу оверлея."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(loc("Опыт работы")) {
                TextEditor(text: $viewModel.backgroundContext)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 160)
                Text(loc("Опишите свой опыт, стек и примеры проектов — это добавляется в инструкции ИИ, чтобы ответы звучали от вашего лица и не выдумывали чужой опыт. Отправляется в OpenAI только вместе с инструкциями, когда активен режим Answers."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(loc("Модели")) {
                TextField(loc("Whisper модель"), text: $viewModel.whisperModelID)
                TextField(loc("Модель саммари"), text: $viewModel.summaryModelID)
            }

            Section(loc("Хранение аудио")) {
                Toggle(loc("Сохранять аудио на диск"), isOn: $viewModel.audioStorageEnabled)
                Text(loc("Выключено по умолчанию. При включении системный звук и микрофон записи сохраняются как WAV-файлы отдельно для каждой встречи."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(loc("Открыть папку с записями")) { viewModel.openRecordingsFolder() }
            }

            Section(loc("VAD (developer)")) {
                LabeledContent(loc("Threshold"), value: String(format: "%.2f", viewModel.vadThreshold))
                Slider(value: $viewModel.vadThreshold, in: 0...1)
                Stepper(loc("Prefix padding:") + " \(viewModel.vadPrefixPaddingMs) ms", value: $viewModel.vadPrefixPaddingMs, in: 0...1000, step: 50)
                Stepper(loc("Silence duration:") + " \(viewModel.vadSilenceDurationMs) ms", value: $viewModel.vadSilenceDurationMs, in: 0...2000, step: 50)
            }
        }
        .formStyle(.grouped)
        .task { await viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await viewModel.refreshPermissionStatuses() }
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, status: PermissionStatus, onRequest: @escaping () -> Void, onOpenSettings: @escaping () -> Void) -> some View {
        HStack {
            LabeledContent(title, value: statusLabel(status))
            Spacer()
            switch status {
            case .authorized:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .notDetermined:
                Button(loc("Запросить доступ"), action: onRequest)
            case .denied:
                Button(loc("Открыть Настройки системы"), action: onOpenSettings)
            }
        }
    }

    private func statusLabel(_ status: PermissionStatus) -> String {
        switch status {
        case .authorized: loc("разрешено")
        case .denied: loc("отклонено")
        case .notDetermined: loc("не запрошено")
        }
    }
}
