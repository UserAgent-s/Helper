import AppKit
import Domain
import SwiftUI

struct GeneralSettingsTab: View {
    var body: some View {
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
        }
        .formStyle(.grouped)
    }
}

struct AudioSettingsTab: View {
    @Bindable var viewModel: AudioSettingsViewModel
    @State private var exclusionCandidate = ""

    var body: some View {
        Form {
            Section(loc("Источник системного звука")) {
                Picker(loc("Источник"), selection: Binding(
                    get: { viewModel.sourceMode },
                    set: { mode in
                        Task {
                            switch mode {
                            case .wholeSystem: await viewModel.selectWholeSystem()
                            case .chrome: await viewModel.selectChromePreset()
                            case .application:
                                if let first = viewModel.runningApplications.first {
                                    await viewModel.selectApplication(bundleID: first.bundleID)
                                }
                            }
                        }
                    }
                )) {
                    Text(loc("Весь звук Mac")).tag(AudioSettingsViewModel.SourceMode.wholeSystem)
                    Text(loc("Только Google Chrome (Meet)")).tag(AudioSettingsViewModel.SourceMode.chrome)
                    Text(loc("Приложение…")).tag(AudioSettingsViewModel.SourceMode.application)
                }
                .pickerStyle(.radioGroup)
                if viewModel.sourceMode == .application {
                    Picker(loc("Приложение"), selection: Binding(
                        get: { viewModel.selectedApplicationBundleID ?? "" },
                        set: { bundleID in Task { await viewModel.selectApplication(bundleID: bundleID) } }
                    )) {
                        if let selected = viewModel.selectedApplicationBundleID,
                           !viewModel.runningApplications.contains(where: { $0.bundleID == selected }) {
                            Text(selected + " " + loc("(не запущен)")).tag(selected)
                        }
                        ForEach(viewModel.runningApplications, id: \.bundleID) { app in
                            Text(app.name).tag(app.bundleID)
                        }
                    }
                }
                if viewModel.sourceMode == .wholeSystem {
                    ForEach(viewModel.exclusions, id: \.self) { bundleID in
                        HStack {
                            Text(loc("Не слушать:") + " " + viewModel.applicationName(for: bundleID))
                            Spacer()
                            Button(loc("Убрать")) { Task { await viewModel.removeExclusion(bundleID: bundleID) } }
                        }
                    }
                    HStack {
                        Picker(loc("Исключить приложение"), selection: $exclusionCandidate) {
                            Text(loc("Выберите…")).tag("")
                            ForEach(viewModel.runningApplications.filter { !viewModel.exclusions.contains($0.bundleID) }, id: \.bundleID) { app in
                                Text(app.name).tag(app.bundleID)
                            }
                        }
                        Button(loc("Исключить")) {
                            let candidate = exclusionCandidate
                            exclusionCandidate = ""
                            Task { await viewModel.excludeApplication(bundleID: candidate) }
                        }
                        .disabled(exclusionCandidate.isEmpty)
                    }
                }
                Text(loc("В режиме ответов весь выбранный звук уходит в OpenAI. Звук самого UserAgent057 не захватывается никогда. Если выбранное приложение не запущено, захват идёт со всего звука Mac с уведомлением."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section(loc("Уровни")) {
                LevelMeterRow(title: loc("Система"), level: viewModel.levels[.systemAudio])
                LevelMeterRow(title: loc("Я (микрофон)"), level: viewModel.levels[.microphone])
                Text(loc("Индикаторы оживают, когда идёт захват: в режимах ответов и записи."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section(loc("Вывод звука")) {
                LabeledContent(loc("Сейчас")) {
                    Text(AnswerOverlayContentView.routeText(viewModel.currentRoute))
                }
                Picker(loc("Что считать выводом"), selection: $viewModel.outputRoutePolicy) {
                    Text(loc("Определять автоматически")).tag(OutputRoutePolicy.auto)
                    Text(loc("Всегда наушники")).tag(OutputRoutePolicy.headphones)
                    Text(loc("Всегда динамики")).tag(OutputRoutePolicy.speakers)
                }
                if viewModel.echoRisk {
                    Text(loc("Динамики: голос собеседника может попасть в микрофон. Лучше использовать наушники."))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(viewModel.voiceProcessingActive
                    ? loc("Канал «Я» включит эхоподавление macOS (Voice Processing). Звук других приложений приглушается минимально.")
                    : loc("Канал «Я» пишет микрофон без эхоподавления: при наушниках оно не нужно."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle(loc("Канал «Я»: распознавать мои реплики в режиме Answers"), isOn: $viewModel.meChannelEnabled)
                Text(loc("Микрофон отправляется в OpenAI только во время ваших реплик. Пока громко звучит собеседник, реплика не открывается."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section(loc("Микрофон")) {
                Picker(loc("Микрофон"), selection: Binding(
                    get: { viewModel.selectedMicrophoneUID },
                    set: { uid in Task { await viewModel.selectMicrophone(uid: uid) } }
                )) {
                    Text(loc("Системный по умолчанию (без iPhone)")).tag("")
                    if !viewModel.selectedMicrophoneUID.isEmpty,
                       !viewModel.microphoneOptions.contains(where: { $0.uid == viewModel.selectedMicrophoneUID }) {
                        Text(loc("Выбранное устройство не подключено")).tag(viewModel.selectedMicrophoneUID)
                    }
                    ForEach(viewModel.microphoneOptions) { option in
                        Text(option.isEnabled ? option.name : option.name + " " + loc("(iPhone, не используется)"))
                            .tag(option.uid)
                            .disabled(!option.isEnabled)
                    }
                }
                Button(loc("Обновить устройства")) { viewModel.refreshDevices() }
                Text(loc("Микрофон iPhone через Continuity никогда не выбирается автоматически. Если выбранное устройство пропадёт, запись продолжится со встроенного микрофона."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct LevelMeterRow: View {
    let title: String
    let level: AudioLevel?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let fraction = AudioSettingsViewModel.meterFraction(level, now: context.date)
            HStack {
                Text(title)
                    .frame(width: 110, alignment: .leading)
                ProgressView(value: fraction)
                    .tint(fraction > 0.85 ? .red : .green)
                Text(fraction > 0 ? String(format: "%.0f dBFS", level?.rmsDBFS ?? -120) : "—")
                    .font(.caption.monospacedDigit())
                    .frame(width: 80, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct AnswersSettingsTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
    }
}

struct ProfileSettingsTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section(loc("Опыт работы")) {
                TextEditor(text: $viewModel.backgroundContext)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 200)
                Text(loc("Опишите свой опыт, стек и примеры проектов — это добавляется в инструкции ИИ, чтобы ответы звучали от вашего лица и не выдумывали чужой опыт. Отправляется в OpenAI только вместе с инструкциями, когда активен режим Answers."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let profile = viewModel.profile {
                ProfileFolderSection(profile: profile)
            }
            Section(loc("Раскрытие через Claude")) {
                Picker(loc("Модель по умолчанию"), selection: $viewModel.claudeModel) {
                    Text("Claude Sonnet 5.5").tag(ExpansionModelChoice.sonnet)
                    Text("Claude Opus 5.5").tag(ExpansionModelChoice.opus)
                }
                .accessibilityIdentifier("settings.claude.model")
                Toggle(loc("Прогревать кеш профиля при старте сессии"), isOn: $viewModel.claudePrewarmOnSessionStart)
                    .accessibilityIdentifier("settings.claude.prewarm")
                Text(viewModel.hasStoredAnthropicAPIKey
                    ? loc("Ключ Anthropic сохранён. Раскрытие запускается из веб-панели; профиль отправляется в Anthropic и кешируется на час.")
                    : loc("Ключ Anthropic не задан — раскрытие недоступно. Добавьте его во вкладке «Аккаунты»."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(loc("Прогрев один раз записывает профиль в кеш Anthropic (≈$0.12 для Sonnet на профиле 80 КБ), после чего каждое раскрытие читает его примерно в 10 раз дешевле."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await viewModel.profile?.reload() }
    }
}

struct ProfileFolderSection: View {
    @Bindable var profile: ProfileSettingsViewModel

    var body: some View {
        Section(loc("MD-профиль")) {
            HStack {
                Text(profile.folderPath ?? loc("Папка не выбрана — используется «Опыт работы»"))
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button(loc("Выбрать папку…")) { profile.chooseFolder() }
                    .accessibilityIdentifier("settings.profile.chooseFolder")
                if profile.folderPath != nil {
                    Button(loc("Перечитать")) { Task { await profile.reload() } }
                    Button(loc("Отключить"), role: .destructive) { Task { await profile.clearFolder() } }
                }
            }
            statusView
            if !profile.candidates.isEmpty {
                ForEach(profile.candidates) { candidate in
                    Toggle(isOn: Binding(
                        get: { profile.isSelected(candidate.relativePath) },
                        set: { isOn in Task { await profile.setSelected(candidate.relativePath, isOn) } }
                    )) {
                        HStack {
                            Text(candidate.relativePath).font(.callout.monospaced())
                            Spacer()
                            Text(ProfileSettingsViewModel.formatBytes(candidate.byteCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Text(profile.usesDefaultSelection ? loc("Выбор по умолчанию: 01, 02, 03") : loc("Выбор изменён вручную"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(loc("Сбросить выбор")) { Task { await profile.resetSelection() } }
                        .disabled(profile.usesDefaultSelection)
                }
            }
            Text(loc("Файлы *.md читаются из папки и подпапок первого уровня. Профиль уходит в Anthropic при раскрытии ответа через Claude; ключевые слова (имена, технологии) — в OpenAI для точной расшифровки."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch profile.status {
        case .noFolder:
            EmptyView()
        case .ok, .warning:
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: loc("Файлов: %d · %@ · ≈%d токенов"), profile.documentCount, ProfileSettingsViewModel.formatBytes(profile.totalBytes), profile.estimatedTokens))
                    .font(.caption)
                if profile.status == .warning {
                    Text(loc("Профиль больше 100 КБ: раскрытия будут дороже и медленнее. Лимит — 256 КБ."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !profile.keywords.isEmpty {
                    Text(loc("Ключевые слова для расшифровки:") + " " + profile.keywords.prefix(15).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        case .error(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("settings.profile.error")
        }
    }
}

struct DeviceRoleSettingsTab: View {
    @Bindable var viewModel: SettingsViewModel
    var navigationState: AppNavigationState? = nil
    @Environment(\.openWindow) private var openWindow
    @State private var isConfirmingRevokeAll = false

    var body: some View {
        Form {
            Section(loc("Роль этого Mac")) {
                Picker(loc("Роль"), selection: $viewModel.deviceRole) {
                    Text(loc("Основной (захватывает звук)")).tag(DeviceRole.primary)
                    Text(loc("Клиент (управление и подсказки)")).tag(DeviceRole.client)
                }
                .pickerStyle(.radioGroup)
                .disabled(true)
                Text(loc("Роль «Клиент» и второй экран по локальной сети появятся на этапе M2b. Сейчас этот Mac всегда основной."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section(loc("Веб-панель второго экрана")) {
                Toggle(loc("Включить сервер веб-панели в локальной сети"), isOn: $viewModel.companionServerEnabled)
                Text(companionStatus)
                    .font(.caption)
                    .foregroundStyle(viewModel.companionStartFailed ? .red : .secondary)
                ForEach(viewModel.companionURLs, id: \.self) { url in
                    Text(url)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                HStack {
                    TextField(loc("Порт"), text: $viewModel.companionPortText)
                        .frame(width: 120)
                        .onSubmit { Task { await viewModel.commitCompanionPort() } }
                    Button(loc("Применить")) { Task { await viewModel.commitCompanionPort() } }
                        .disabled(!viewModel.isCompanionPortValid)
                }
                Toggle(loc("Только этот Mac (127.0.0.1), без доступа из сети"), isOn: $viewModel.companionLoopbackOnly)
                Button(loc("Подключить устройство…")) {
                    navigationState?.markPairingRequested()
                    openWindow(id: PairingWindow.id)
                }
                .disabled(navigationState == nil)
            }
            Section(loc("Сопряжённые устройства")) {
                if viewModel.companionDevices.isEmpty {
                    Text(loc("Нет сопряжённых устройств"))
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.companionDevices) { device in
                    HStack {
                        Image(systemName: device.isConnected ? "dot.radiowaves.left.and.right" : "laptopcomputer")
                            .foregroundStyle(device.isConnected ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(deviceSubtitle(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(loc("Отозвать"), role: .destructive) {
                            Task { await viewModel.revokeCompanionDevice(device.id) }
                        }
                    }
                }
                HStack {
                    Button(loc("Обновить")) { Task { await viewModel.loadCompanionDevices() } }
                    Spacer()
                    Button(loc("Отозвать всё"), role: .destructive) { isConfirmingRevokeAll = true }
                        .disabled(viewModel.companionDevices.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(loc("Отозвать все устройства?"), isPresented: $isConfirmingRevokeAll) {
            Button(loc("Отозвать всё"), role: .destructive) {
                Task { await viewModel.revokeAllCompanionDevices() }
            }
            Button(loc("Отмена"), role: .cancel) {}
        } message: {
            Text(loc("Все подключённые панели будут сразу отключены, для нового подключения понадобится сопряжение."))
        }
    }
}

extension DeviceRoleSettingsTab {
    var companionStatus: String {
        if viewModel.companionStartFailed {
            return loc("Не удалось запустить сервер")
        }
        guard viewModel.companionServerEnabled, let port = viewModel.companionPort else {
            return loc("Сервер выключен")
        }
        return loc("Сервер работает, порт") + " \(port)"
    }

    func deviceSubtitle(_ device: CompanionDeviceRow) -> String {
        let added = device.createdAt.formatted(date: .abbreviated, time: .shortened)
        guard let seen = device.lastSeenAt else { return loc("Добавлено") + " " + added }
        let status = device.isConnected ? loc("на связи") : loc("был") + " " + seen.formatted(date: .abbreviated, time: .shortened)
        return status
    }
}

struct SessionsDataSettingsTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section(loc("Хранение аудио")) {
                Toggle(loc("Сохранять аудио на диск"), isOn: $viewModel.audioStorageEnabled)
                Text(loc("Выключено по умолчанию. При включении системный звук и микрофон записи сохраняются как WAV-файлы отдельно для каждой встречи."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(loc("Открыть папку с записями")) { viewModel.openRecordingsFolder() }
            }
            Section(loc("Итоги сессии")) {
                Toggle(loc("Делать саммари после остановки сессии"), isOn: $viewModel.autoSummaryOnStop)
                    .accessibilityIdentifier("settings.sessions.autoSummaryOnStop")
                Text(loc("Выключено по умолчанию. При включении транскрипт сессии отправляется в OpenAI для саммари. Заголовок сессии создаётся локально всегда."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(loc("Экспорт встреч")) {
                Toggle(loc("Автоматически экспортировать встречу после записи"), isOn: $viewModel.meetingAutoExportEnabled)
                Text(loc("Выключено по умолчанию. Транскрипт и аудио попадают в ~/Documents/UserAgent057/Exports. Рабочий стол не используется."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(loc("Открыть папку экспорта")) { viewModel.openExportsFolder() }
            }
            Section(loc("Срок хранения истории")) {
                Picker(loc("Хранить"), selection: $viewModel.historyRetentionDays) {
                    Text(loc("Бессрочно")).tag(0)
                    Text(loc("30 дней")).tag(30)
                    Text(loc("90 дней")).tag(90)
                    Text(loc("365 дней")).tag(365)
                }
                .accessibilityIdentifier("settings.sessions.retentionDays")
                Text(loc("Завершённые сессии старше срока удаляются при запуске и раз в сутки вместе с аудио и поисковым индексом. Закреплённые и текущая сессия не удаляются."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(loc("Хранить тексты экрана"), isOn: $viewModel.keepScreenTexts)
                    .accessibilityIdentifier("settings.sessions.keepScreenTexts")
                Text(loc("Если выключить, распознанные тексты экрана удаляются из всех сессий, кроме текущей."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AccountsSettingsTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section(loc("API-ключ OpenAI")) {
                SecureField("sk-…", text: $viewModel.apiKeyInput)
                    .accessibilityIdentifier("settings.accounts.openaiKey")
                if let warning = viewModel.apiKeyWarning {
                    Text(warning).font(.caption).foregroundStyle(.red)
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
            Section(loc("Anthropic (Claude)")) {
                SecureField("sk-ant-…", text: $viewModel.anthropicAPIKeyInput)
                    .accessibilityIdentifier("settings.accounts.anthropicKey")
                if let warning = viewModel.anthropicAPIKeyWarning {
                    Text(warning).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text(loc("Статус:") + " " + viewModel.anthropicAPIKeyStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(loc("Сохранить")) { viewModel.saveAnthropicAPIKey() }
                        .disabled(viewModel.anthropicAPIKeyInput.isEmpty)
                    Button(loc("Удалить"), role: .destructive) { viewModel.deleteAnthropicAPIKey() }
                }
                Text(loc("Нужен для глубоких раскрытий через Claude. Хранится отдельно от ключа OpenAI."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section(loc("Разрешения")) {
                PermissionRow(
                    title: "Screen Recording",
                    status: viewModel.screenRecordingStatus,
                    onRequest: viewModel.requestScreenRecordingAccess,
                    onOpenSettings: viewModel.openScreenRecordingSystemSettings
                )
                PermissionRow(
                    title: "Microphone",
                    status: viewModel.microphoneStatus,
                    onRequest: viewModel.requestMicrophoneAccess,
                    onOpenSettings: viewModel.openMicrophoneSystemSettings
                )
                Text(loc("Микрофон нужен только для recording; answers работает без него, если выбран системный источник."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceSettingsTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section(loc("Оверлей ответов")) {
                Toggle(loc("Показывать оверлей на этом Mac"), isOn: $viewModel.overlayEnabled)
                    .accessibilityIdentifier("settings.overlayEnabled")
                Text(loc("Выключите, если показываете экран: ответы будут видны только в веб-панели на втором устройстве. Иконка в строке меню и окна приложения остаются на месте."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettingsTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section(loc("Модели")) {
                TextField(loc("Whisper модель"), text: $viewModel.whisperModelID)
                TextField(loc("Модель саммари"), text: $viewModel.summaryModelID)
            }
            Section(loc("Захват системного звука (developer)")) {
                Picker(loc("Backend"), selection: $viewModel.systemAudioBackend) {
                    Text("ScreenCaptureKit").tag(SystemAudioBackend.screenCaptureKit)
                    Text("Core Audio tap").tag(SystemAudioBackend.coreAudioTap)
                }
                Text(loc("Экспериментальный переключатель для сравнения. Применяется после перезапуска приложения. Core Audio tap спросит отдельное разрешение «Запись системного звука»."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section(loc("VAD (developer)")) {
                LabeledContent(loc("Threshold"), value: String(format: "%.2f", viewModel.vadThreshold))
                Slider(value: $viewModel.vadThreshold, in: 0...1)
                Stepper(loc("Prefix padding:") + " \(viewModel.vadPrefixPaddingMs) ms", value: $viewModel.vadPrefixPaddingMs, in: 0...1000, step: 50)
                Stepper(loc("Silence duration:") + " \(viewModel.vadSilenceDurationMs) ms", value: $viewModel.vadSilenceDurationMs, in: 0...2000, step: 50)
            }
            Section(loc("Диагностика")) {
                Toggle(loc("Разрешить содержимое в экспорте диагностики"), isOn: $viewModel.diagnosticsIncludeContentOptIn)
                Text(loc("По умолчанию экспорт содержит только версию, разрешения, режим и метрики задержки. С галочкой при экспорте появится запрос на включение стенограмм и Q&A."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    let title: String
    let status: PermissionStatus
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack {
            LabeledContent(title, value: label)
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

    private var label: String {
        switch status {
        case .authorized: loc("разрешено")
        case .denied: loc("отклонено")
        case .notDetermined: loc("не запрошено")
        }
    }
}
