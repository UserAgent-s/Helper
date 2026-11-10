import Domain
import SecurityStore
import SwiftUI
import Transcription

struct OnboardingView: View {
    let secretStoring: any SecretStoring
    let whisperKitTranscribing: WhisperKitTranscribing
    let permissionsChecking: any PermissionsChecking
    let onFinish: () -> Void

    @State private var apiKeyInput = ""
    @State private var hasSavedAPIKey = false
    @State private var apiKeyWarning: String?
    @State private var anthropicAPIKeyInput = ""
    @State private var hasSavedAnthropicAPIKey = false
    @State private var anthropicAPIKeyWarning: String?
    @State private var modelCheckOutcome: ModelCheckOutcome?
    @State private var isCheckingModel = false
    @State private var screenRecordingStatus = PermissionStatus.notDetermined
    @State private var microphoneStatus = PermissionStatus.notDetermined

    private enum ModelCheckOutcome {
        case ready
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(loc("Что захватывает UserAgent057"))
                    .font(.title2)

                VStack(alignment: .leading, spacing: 12) {
                    onboardingRow(
                        title: loc("Passive"),
                        detail: loc("Ничего не захватывается: ни системный звук, ни микрофон, ни сеть. Разрешения не запрашиваются, пока вы не выберете другой режим.")
                    )
                    onboardingRow(
                        title: loc("Answers"),
                        detail: loc("Запрашивает разрешение Screen Recording. Системный звук выбранного приложения отправляется в OpenAI Realtime API для быстрых ответов. Микрофон не требуется. Полный разговор не сохраняется — только показанные пары вопрос-ответ.")
                    )
                    onboardingRow(
                        title: loc("Recording"),
                        detail: loc("Запрашивает разрешения Screen Recording и Microphone. Звук транскрибируется локально (WhisperKit). В сеть ничего не отправляется. Исходное аудио не сохраняется на диск по умолчанию. Источник звука для Answers можно выбрать в Настройках.")
                    )
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(loc("Разрешения")).font(.headline)
                    permissionRow(title: "Screen Recording", status: screenRecordingStatus) {
                        Task { screenRecordingStatus = await permissionsChecking.request(.screenRecording) }
                    } onOpenSettings: {
                        SystemSettingsLinks.openScreenRecordingSettings()
                    }
                    permissionRow(title: "Microphone", status: microphoneStatus) {
                        Task { microphoneStatus = await permissionsChecking.request(.microphone) }
                    } onOpenSettings: {
                        SystemSettingsLinks.openMicrophoneSettings()
                    }
                    Text(loc("Можно пропустить — разрешения запросятся автоматически при первом входе в соответствующий режим."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(loc("API-ключ OpenAI (для Answers и саммари)")).font(.headline)
                    SecureField("sk-…", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                    keyStatusRow(input: apiKeyInput, warning: apiKeyWarning, saved: hasSavedAPIKey) {
                        saveKey(provider: .openAI)
                    }
                    Text(loc("API-ключ Anthropic (для раскрытий через Claude)")).font(.headline)
                        .padding(.top, 6)
                    SecureField("sk-ant-…", text: $anthropicAPIKeyInput)
                        .textFieldStyle(.roundedBorder)
                    keyStatusRow(input: anthropicAPIKeyInput, warning: anthropicAPIKeyWarning, saved: hasSavedAnthropicAPIKey) {
                        saveKey(provider: .anthropic)
                    }
                    Text(loc("Можно пропустить и добавить позже в Настройках."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(loc("Локальная модель Whisper (для Recording)")).font(.headline)
                    HStack {
                        Button(isCheckingModel ? loc("Проверяем…") : loc("Проверить/загрузить модель")) { checkModel() }
                            .disabled(isCheckingModel)
                        switch modelCheckOutcome {
                        case .ready:
                            Text(loc("Модель готова")).font(.caption).foregroundStyle(.secondary)
                        case .failed(let error):
                            Text(loc("Не удалось загрузить:") + " \(error)").font(.caption).foregroundStyle(.secondary)
                        case nil:
                            EmptyView()
                        }
                    }
                    Text(loc("Не блокирует Passive — можно закрыть этот экран без проверки."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text(loc("Если на встрече присутствуют другие люди, получите их согласие на запись/обработку речи в соответствии с применимыми правилами."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(loc("Понятно")) { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(minWidth: 460, minHeight: 560)
        .task {
            screenRecordingStatus = await permissionsChecking.status(for: .screenRecording)
            microphoneStatus = await permissionsChecking.status(for: .microphone)
        }
    }

    private func onboardingRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, status: PermissionStatus, onRequest: @escaping () -> Void, onOpenSettings: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.callout)
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

    private func keyStatusRow(input: String, warning: String?, saved: Bool, onSave: @escaping () -> Void) -> some View {
        HStack {
            Button(loc("Сохранить"), action: onSave)
                .disabled(input.isEmpty)
            if let warning {
                Text(warning).font(.caption).foregroundStyle(.secondary)
            } else if saved {
                Text(loc("Сохранён")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveKey(provider: SecretProvider) {
        let input = provider == .openAI ? apiKeyInput : anthropicAPIKeyInput
        var warning: String?
        var saved = false
        switch APIKeyFormatValidator.check(input, for: provider) {
        case .valid(let key):
            if (try? secretStoring.store(apiKey: key, provider: provider)) != nil {
                saved = true
            } else {
                warning = loc("Не удалось сохранить ключ")
            }
        case .belongsTo(.anthropic):
            warning = loc("Это ключ Anthropic (sk-ant-…) — вставьте его в поле Anthropic")
        case .belongsTo(.openAI):
            warning = loc("Это ключ OpenAI — вставьте его в поле OpenAI")
        case .invalidFormat:
            warning = loc("Формат ключа выглядит некорректным")
        }
        switch provider {
        case .openAI:
            apiKeyWarning = warning
            hasSavedAPIKey = saved
            if saved { apiKeyInput = "" }
        case .anthropic:
            anthropicAPIKeyWarning = warning
            hasSavedAnthropicAPIKey = saved
            if saved { anthropicAPIKeyInput = "" }
        }
    }

    private func checkModel() {
        isCheckingModel = true
        modelCheckOutcome = nil
        Task {
            do {
                _ = try await whisperKitTranscribing.prewarm()
                modelCheckOutcome = .ready
            } catch {
                modelCheckOutcome = .failed("\(error)")
            }
            isCheckingModel = false
        }
    }
}
