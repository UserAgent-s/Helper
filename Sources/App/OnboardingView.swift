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
    @State private var hasAPIKeyFormatWarning = false
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
                    HStack {
                        Button(loc("Сохранить в Keychain")) { saveAPIKey() }
                            .disabled(apiKeyInput.isEmpty)
                        if hasAPIKeyFormatWarning {
                            Text(loc("Формат ключа выглядит некорректным")).font(.caption).foregroundStyle(.secondary)
                        } else if hasSavedAPIKey {
                            Text(loc("Сохранён")).font(.caption).foregroundStyle(.secondary)
                        }
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

    private func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard APIKeyFormatValidator.isPlausibleFormat(trimmed) else {
            hasAPIKeyFormatWarning = true
            hasSavedAPIKey = false
            return
        }
        try? secretStoring.store(apiKey: trimmed)
        apiKeyInput = ""
        hasAPIKeyFormatWarning = false
        hasSavedAPIKey = true
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
