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
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section(loc("Источник системного звука (answers)")) {
                Picker(loc("Приложение"), selection: $viewModel.preferredAudioSourceBundleID) {
                    Text(loc("Весь системный звук")).tag("")
                    if !viewModel.preferredAudioSourceBundleID.isEmpty,
                       !viewModel.runningApplications.contains(where: { $0.bundleID == viewModel.preferredAudioSourceBundleID }) {
                        Text("\(viewModel.preferredAudioSourceBundleID) " + loc("(не запущен)")).tag(viewModel.preferredAudioSourceBundleID)
                    }
                    ForEach(viewModel.runningApplications, id: \.bundleID) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
                .onChange(of: viewModel.preferredAudioSourceBundleID) { viewModel.savePreferredAudioSource() }
                HStack {
                    Button(loc("Весь системный звук")) { viewModel.selectWholeSystem() }
                    Button(loc("Только Chrome")) { viewModel.selectChromeOnlyPreset() }
                }
                Text(loc("По умолчанию захватывается весь системный звук. «Только Chrome» — пресет для Google Meet в браузере. Устройство вывода (наушники, динамики Mac) выбирается в системном меню звука macOS."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section(loc("Вывод звука")) {
                LabeledContent(loc("Сейчас")) {
                    Text(AnswerOverlayContentView.routeText(viewModel.currentOutputRoute))
                }
                Picker(loc("Что считать выводом"), selection: $viewModel.outputRoutePolicy) {
                    Text(loc("Определять автоматически")).tag(OutputRoutePolicy.auto)
                    Text(loc("Всегда наушники")).tag(OutputRoutePolicy.headphones)
                    Text(loc("Всегда динамики")).tag(OutputRoutePolicy.speakers)
                }
                if OutputRouteClassifier.echoRisk(viewModel.currentOutputRoute, policy: viewModel.outputRoutePolicy) {
                    Text(loc("Динамики: голос собеседника может попасть в микрофон. Лучше использовать наушники."))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(loc("Если USB- или Bluetooth-устройство на самом деле колонка, а не наушники, выберите «Всегда динамики»."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section(loc("Микрофон")) {
                Picker(loc("Микрофон"), selection: $viewModel.microphoneDeviceUID) {
                    Text(loc("Системный по умолчанию (без iPhone)")).tag("")
                    if !viewModel.microphoneDeviceUID.isEmpty,
                       !viewModel.inputDevices.contains(where: { $0.uid == viewModel.microphoneDeviceUID }) {
                        Text(loc("Выбранное устройство не подключено")).tag(viewModel.microphoneDeviceUID)
                    }
                    ForEach(viewModel.inputDevices) { device in
                        if device.transport.isContinuity {
                            Text(device.name + " " + loc("(iPhone, не используется)")).tag(device.uid).disabled(true)
                        } else {
                            Text(device.name).tag(device.uid)
                        }
                    }
                }
                .onChange(of: viewModel.microphoneDeviceUID) { viewModel.saveMicrophoneSelection() }
                Button(loc("Обновить список")) { viewModel.refreshInputDevices() }
                Text(loc("Микрофон iPhone через Continuity никогда не выбирается автоматически. Если выбранное устройство пропадёт, запись продолжится со встроенного микрофона."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
            Section(loc("MD-профиль и Claude")) {
                LabeledContent(loc("Папка профиля"), value: loc("появится в M5"))
                Text(loc("Профиль из MD-файлов и расширение ответов через Claude подключаются на этапе M5."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct DeviceRoleSettingsTab: View {
    @Bindable var viewModel: SettingsViewModel

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
        }
        .formStyle(.grouped)
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
            Section(loc("Срок хранения истории")) {
                Picker(loc("Хранить"), selection: $viewModel.historyRetentionDays) {
                    Text(loc("Бессрочно")).tag(0)
                    Text(loc("30 дней")).tag(30)
                    Text(loc("90 дней")).tag(90)
                    Text(loc("365 дней")).tag(365)
                }
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
            Section(loc("Anthropic (Claude)")) {
                SecureField("sk-ant-…", text: .constant(""))
                    .disabled(true)
                Text(loc("Ключ Anthropic подключается на этапе M5."))
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
