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
        .frame(minWidth: 560, minHeight: 640)
    }

    private var settingsForm: some View {
        Form {
            if viewModel.sessionStatus.hasUnappliedSettings {
                Section {
                    Label(loc("Часть изменений ещё не применена к активной сессии Answers — они вступят в силу при следующем запуске Answers."), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            providerSection
            keysSection
            answerSection
            profileSection
            spendSection

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
                Text(loc("Оверлей — обычное окно поверх других: при демонстрации экрана он может быть виден собеседнику. Изменение применится к следующему показу оверлея."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let remote = viewModel.remoteDisplay {
                RemoteDisplaySettingsSection(coordinator: remote)
            }

            Section(loc("Модели Recording и саммари")) {
                TextField(loc("Whisper модель"), text: $viewModel.whisperModelID)
                TextField(loc("Модель саммари"), text: $viewModel.summaryModelID)
            }

            Section(loc("Хранение аудио")) {
                Toggle(loc("Сохранять аудио на диск"), isOn: $viewModel.audioStorageEnabled)
                Text(loc("Выключено по умолчанию. Относится только к Recording: системный звук и микрофон сохраняются как WAV-файлы для каждой встречи. Answers никогда не пишет аудио на диск."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(loc("Открыть папку с записями")) { viewModel.openRecordingsFolder() }
            }

            Section(loc("Диагностика")) {
                Toggle(loc("Включать текст вопросов, ответов и транскрипты в файл диагностики"), isOn: $viewModel.diagnosticsIncludeContent)
                Text(loc("По умолчанию выключено: файл диагностики содержит только режим, провайдера, модель, счётчики, задержки и коды ошибок — без аудио, текста разговора, профиля и ключей."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(loc("VAD OpenAI Realtime (developer)")) {
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

    private var providerSection: some View {
        Section(loc("Провайдер и модель подсказок")) {
            Picker(loc("Провайдер"), selection: $viewModel.answerProvider) {
                Text("OpenAI Realtime").tag(AnswerProvider.openAIRealtime)
                Text("Anthropic Claude").tag(AnswerProvider.anthropicClaude)
            }
            .pickerStyle(.segmented)
            .disabled(!viewModel.canChangeProviderOrModel)

            Picker(loc("Модель"), selection: $viewModel.modelPickerTag) {
                ForEach(viewModel.availableModels) { model in
                    Text(model.displayName).tag(model.id)
                }
                Text(loc("Другая (указать ID вручную)…")).tag(SettingsViewModel.customModelTag)
            }
            .disabled(!viewModel.canChangeProviderOrModel)

            if viewModel.isCustomModelSelected {
                HStack {
                    TextField(loc("ID модели"), text: $viewModel.customModelInput)
                        .disabled(!viewModel.canChangeProviderOrModel)
                    Button(loc("Применить")) { viewModel.applyCustomModel() }
                        .disabled(!viewModel.canChangeProviderOrModel || viewModel.customModelInput.isEmpty)
                }
                Text(loc("Модель, указанная вручную, не проверена: если провайдер её не знает или она недоступна вашему ключу, сессия остановится с понятной ошибкой. Стоимость для неё будет «неизвестно»."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let error = viewModel.customModelError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Text(viewModel.selectedModelPricingText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !viewModel.canChangeProviderOrModel {
                Text(loc("Провайдер и модель меняются только в Passive. Сначала остановите текущую сессию (переключитесь в Passive)."))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if viewModel.answerProvider == .anthropicClaude {
                Toggle(loc("Разрешить Anthropic ответить резервной моделью Claude при отказе (server-side fallback)"), isOn: $viewModel.anthropicServerSideFallback)
                Text(loc("Только для Opus 5.5 и Sonnet 5.5. Резервная модель — тоже Anthropic; данные другому провайдеру не отправляются. Фактическая модель показывается в статусе сессии."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(ProviderText.outboundData(viewModel.answerProvider))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var keysSection: some View {
        Section(loc("API-ключи (хранятся в Keychain)")) {
            keyRow(title: loc("OpenAI API key"), placeholder: "sk-…", field: viewModel.openAIKey)
            keyRow(title: loc("Anthropic API key"), placeholder: "sk-ant-…", field: viewModel.anthropicKey)
            if let note = viewModel.keyMigrationNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Text(loc("Claude API оплачивается отдельно по ключу из console.anthropic.com; подписка Claude Pro/Max/Claude Code его не оплачивает и ключом не является."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func keyRow(title: String, placeholder: String, field: APIKeyFieldState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            SecureField(placeholder, text: Bindable(field).input)
            HStack {
                Text(loc("Статус:") + " " + (field.hasStoredKey ? loc("сохранён") : loc("не задан")) + (field.usesLegacyStorage ? " " + loc("(в старом хранилище, не в Keychain)") : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(loc("Сохранить")) { viewModel.saveKey(field) }
                    .disabled(field.input.isEmpty)
                Button(loc("Удалить"), role: .destructive) { viewModel.deleteKey(field) }
                    .disabled(!field.hasStoredKey)
            }
            if field.formatWarning {
                Text(field.provider == .anthropicClaude ? loc("Формат ключа выглядит некорректным (ожидается sk-ant-…)") : loc("Формат ключа выглядит некорректным (ожидается sk-…)"))
                    .font(.caption).foregroundStyle(.red)
            }
            if let error = field.saveError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var answerSection: some View {
        Section(loc("Подсказки")) {
            Picker(loc("Когда отвечать"), selection: $viewModel.answerTriggerMode) {
                Text(loc("Автоматически")).tag(AnswerTriggerMode.automatic)
                Text(loc("Только по нажатию")).tag(AnswerTriggerMode.manualOnly)
            }
            .pickerStyle(.segmented)
            Text(loc("«Только по нажатию» накапливает вопрос и не отправляет запрос на ответ, пока вы не нажмёте «Ответить сейчас» (⌥↩). В OpenAI Realtime аудио при этом всё равно передаётся непрерывно."))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Picker(loc("Длина ответа"), selection: $viewModel.answerLength) {
                Text(loc("Коротко")).tag(AnswerLength.short)
                Text(loc("Стандартно")).tag(AnswerLength.standard)
                Text(loc("Подробно")).tag(AnswerLength.detailed)
            }
            .pickerStyle(.segmented)

            Text(loc("Роль эксперта и правила ответа задаются профильными областями в окне «Память»: активные области и их заметки входят в инструкции, остальные не покидают Mac."))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Stepper(loc("Память прошлых ответов из Истории:") + " \(viewModel.answersMemoryCount)", value: $viewModel.answersMemoryCount, in: 0...10)
            Text(loc("Последние ответы из прошлых сессий добавляются в инструкции, чтобы подсказки не противоречили сказанному раньше. 0 — выключено. Эти ответы отправляются провайдеру."))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(loc("Сначала суть, затем детали по выбранной длине. Правила общие для обоих провайдеров."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var profileSection: some View {
        Section(loc("Профиль кандидата и вакансия (общие для провайдеров)")) {
            profileEditor(loc("Основной стек"), \.primaryStack, height: 50)
            profileEditor(loc("Реальный опыт"), \.realExperience, height: 90)
            VStack(alignment: .leading, spacing: 4) {
                profileEditor(loc("Реальные кейсы: ситуация, ограничения, решение, альтернативы, результат"), \.realCases, height: 140)
                Button(loc("Вставить шаблон кейса")) { viewModel.insertCaseTemplate() }
                    .font(.caption)
            }
            profileEditor(loc("Области без коммерческого опыта"), \.noCommercialExperience, height: 50)
            profileEditor(loc("Целевая роль"), \.targetRole, height: 40)
            profileEditor(loc("Описание вакансии и темы интервью"), \.vacancyContext, height: 90)
            Text(loc("Заполняйте только правдой: пустое поле модель считает неизвестным, а не придумывает. Не вставляйте конфиденциальные данные работодателей — профиль отправляется выбранному провайдеру вместе с инструкциями."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func profileEditor(_ title: String, _ keyPath: WritableKeyPath<CandidateProfile, String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { viewModel.candidateProfile[keyPath: keyPath] },
                set: { viewModel.updateProfile(keyPath, $0) }
            ))
            .font(.system(size: 12))
            .frame(minHeight: height)
        }
    }

    private var spendSection: some View {
        Section(loc("Расходы")) {
            HStack {
                Text(loc("Порог на сессию, $"))
                TextField("", text: $viewModel.spendLimitText)
                    .frame(width: 90)
            }
            Picker(loc("При достижении"), selection: $viewModel.spendLimitMode) {
                Text(loc("Только предупредить")).tag(SpendLimitMode.warnOnly)
                Text(loc("Остановить сессию")).tag(SpendLimitMode.stopSession)
            }
            .pickerStyle(.segmented)
            Text(loc("Это оценка по usage и опубликованному тарифу, а не счёт. Остановка срабатывает после получения usage: запрос, уже находящийся в обработке, может превысить порог. Жёсткий денежный лимит задаётся только в консоли провайдера."))
                .font(.caption2)
                .foregroundStyle(.secondary)
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

struct RemoteDisplaySettingsSection: View {
    @Bindable var coordinator: RemoteDisplayCoordinator
    @State private var portText = ""

    var body: some View {
        Section(loc("Удалённый экран (другой Mac или телефон в той же сети)")) {
            Toggle(loc("Показывать подсказки на другом устройстве"), isOn: $coordinator.isEnabled)
            HStack {
                Text(loc("Порт"))
                TextField("", text: $portText)
                    .frame(width: 90)
                    .onSubmit { applyPort() }
                Button(loc("Применить")) { applyPort() }
                    .disabled(Int(portText) == coordinator.port)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(coordinator.startError == nil ? Color.secondary : Color.red)
            }
            if coordinator.status.isRunning {
                ForEach(coordinator.urls, id: \.absoluteString) { url in
                    HStack {
                        Text(url.absoluteString)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button(loc("Копировать")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                        Button(loc("Открыть")) { NSWorkspace.shared.open(url) }
                    }
                }
                if let image = coordinator.qrImage {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 160, height: 160)
                }
                Button(loc("Перевыпустить токен сопряжения")) { coordinator.regenerateToken() }
            }
            Text(loc("Откройте ссылку в браузере второго устройства в той же Wi‑Fi сети. Любой, кто знает ссылку с токеном и находится в вашей сети, видит подсказки и может переключать режимы; передача идёт без шифрования — не включайте в публичных сетях. Токен и текст подсказок не пишутся в логи."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear { portText = String(coordinator.port) }
    }

    private var statusText: String {
        if let error = coordinator.startError { return error }
        guard coordinator.status.isRunning else { return loc("выключен") }
        let clients = coordinator.status.clientCount
        return loc("работает · подключено устройств:") + " \(clients)"
    }

    private func applyPort() {
        guard let value = Int(portText), (1_024...65_000).contains(value) else {
            portText = String(coordinator.port)
            return
        }
        coordinator.port = value
    }
}
