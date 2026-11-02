import AppKit
import SwiftUI
import Domain
import Diagnostics
import Transcription

@MainActor
@Observable
final class ModeSwitcherViewModel {
    private let modeCoordinator: ModeCoordinator

    private(set) var currentMode: AppMode = .passive
    private(set) var phase: ModePhase = .idle
    private(set) var failureReason: ModeFailureReason?
    private(set) var returnedToPassiveConfirmation: Bool = false

    var lastError: String? {
        guard let failureReason else { return nil }
        switch failureReason {
        case .permissionDenied(.screenRecording):
            return loc("Нет доступа к записи экрана. Откройте Настройки и предоставьте разрешение Screen Recording.")
        case .permissionDenied(.microphone):
            return loc("Нет доступа к микрофону. Откройте Настройки и предоставьте разрешение Microphone.")
        case .targetApplicationNotRunning(let bundleID):
            return loc("Приложение") + " «\(bundleID)» " + loc("не запущено. Откройте его и попробуйте снова.")
        case .noControllerRegistered:
            return loc("Этот режим сейчас недоступен.")
        case .provider(let error):
            return loc("Answers не запущен:") + " " + ProviderText.error(error)
        case .unknown:
            return loc("Не удалось запустить режим. Попробуйте ещё раз.")
        }
    }

    init(modeCoordinator: ModeCoordinator) {
        self.modeCoordinator = modeCoordinator
        Task { [weak self] in
            guard let self else { return }
            for await state in self.modeCoordinator.stateUpdates() {
                self.apply(state)
            }
        }
    }

    func select(_ mode: AppMode) {
        Task { [modeCoordinator] in
            _ = await modeCoordinator.requestTransition(to: mode)
        }
    }

    func terminate() {
        NSApp.terminate(nil)
    }

    private func apply(_ state: ModeState) {
        let wasNonPassive = currentMode != .passive
        currentMode = state.mode
        phase = state.phase
        failureReason = state.userFacingError
        returnedToPassiveConfirmation = wasNonPassive && state.mode == .passive && state.phase == .idle
    }
}

struct ModeSwitcherView: View {
    var viewModel: ModeSwitcherViewModel
    var transcriptViewModel: RecordingTranscriptViewModel
    var historyViewModel: HistoryViewModel
    var settingsViewModel: SettingsViewModel
    var settingsStore: AppSettingsStore
    var permissionsChecking: any PermissionsChecking
    var latencyRecording: InMemoryLatencyRecorder
    var navigationState: AppNavigationState
    var whisperKitTranscribing: WhisperKitTranscribing
    var questionAnswerRepository: any QuestionAnswerRepository
    var meetingRepository: any MeetingRepository
    var sessionStatus: SessionStatusViewModel
    var knowledgeBase: KnowledgeBaseViewModel
    var secretStores: [AnswerProvider: any SecretStoring]

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("MeetingAssistant")
                    .font(.title2)
                Spacer()
                Button(loc("Диагностика")) { exportDiagnostics() }
                Button(loc("Мой опыт")) { navigationState.isShowingKnowledgeBase = true }
                Button(loc("Настройки")) { navigationState.isShowingSettings = true }
                Button(loc("История")) { navigationState.isShowingHistory = true }
            }
            Picker(loc("Режим"), selection: Binding(
                get: { viewModel.currentMode },
                set: { viewModel.select($0) }
            )) {
                Text(loc("Passive")).tag(AppMode.passive)
                Text(loc("Answers")).tag(AppMode.answers)
                Text(loc("Recording")).tag(AppMode.recording)
            }
            .pickerStyle(.segmented)

            Text(phaseDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            privacyIndicator

            if viewModel.returnedToPassiveConfirmation {
                Text(loc("Приложение вернулось в Passive"))
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let error = viewModel.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            sessionPanel

            if viewModel.currentMode == .recording {
                liveTranscriptList
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: viewModel.currentMode == .recording ? 520 : 300)
        .sheet(isPresented: Binding(get: { navigationState.isShowingHistory }, set: { navigationState.isShowingHistory = $0 })) {
            HistoryView(viewModel: historyViewModel)
        }
        .sheet(isPresented: Binding(get: { navigationState.isShowingKnowledgeBase }, set: { navigationState.isShowingKnowledgeBase = $0 })) {
            KnowledgeBaseView(viewModel: knowledgeBase)
        }
        .sheet(isPresented: Binding(get: { navigationState.isShowingSettings }, set: { navigationState.isShowingSettings = $0 })) {
            SettingsView(viewModel: settingsViewModel)
        }
        .sheet(isPresented: Binding(get: { navigationState.isShowingOnboarding }, set: { navigationState.isShowingOnboarding = $0 })) {
            OnboardingView(secretStores: secretStores, whisperKitTranscribing: whisperKitTranscribing, permissionsChecking: permissionsChecking) {
                settingsStore.onboardingCompleted = true
                navigationState.isShowingOnboarding = false
            }
        }
        .task { await knowledgeBase.load() }
        .onAppear {
            if !settingsStore.onboardingCompleted {
                navigationState.isShowingOnboarding = true
            }
        }
    }

    private var privacyIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(privacyIndicatorColor)
                .frame(width: 8, height: 8)
            Text(privacyIndicatorText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var privacyIndicatorColor: Color {
        switch viewModel.currentMode {
        case .passive: .gray
        case .answers: .red
        case .recording: .orange
        }
    }

    private var privacyIndicatorText: String {
        switch viewModel.currentMode {
        case .passive: loc("Passive: ничего не захватывается")
        case .answers: sessionStatus.displayedSelection.provider == .openAIRealtime
            ? loc("Answers: системный звук уходит в OpenAI Realtime API")
            : loc("Answers: звук распознаётся локально, текст уходит в Anthropic Claude API")
        case .recording: loc("Recording: аудио обрабатывается только локально")
        }
    }

    private func exportDiagnostics() {
        Task {
            let snapshot = await DiagnosticsExporter.makeSnapshot(
                mode: viewModel.currentMode,
                phase: viewModel.phase,
                permissionsChecking: permissionsChecking,
                latencyRecorder: latencyRecording,
                telemetry: sessionStatus.snapshot,
                includeContent: settingsStore.diagnosticsIncludeContentOptIn,
                questionAnswerRepository: questionAnswerRepository,
                meetingRepository: meetingRepository
            )
            guard let data = try? DiagnosticsExporter.encodeJSON(snapshot) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "diagnostics.json"
            if let window = NSApp.keyWindow ?? NSApp.windows.first {
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else { return }
                    try? data.write(to: url)
                }
            } else {
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    try? data.write(to: url)
                }
            }
        }
    }

    private var sessionPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                statusRow(loc("Провайдер"), sessionStatus.providerLabel)
                statusRow(loc("Модель"), sessionStatus.modelLabel)
                statusRow(loc("Захват"), captureDescription)
                statusRow(loc("Состояние"), sessionStatus.statusText)
                statusRow(loc("Наружу"), viewModel.currentMode == .passive ? loc("ничего (Passive)") : (viewModel.currentMode == .recording ? loc("ничего, Recording работает локально") : sessionStatus.outboundDataDescription))
                statusRow(loc("Сохранение"), storageDescription)
                statusRow(loc("Мой опыт"), sessionStatus.experienceText)
                statusRow(loc("Usage"), sessionStatus.usageText)
                statusRow(loc("Стоимость"), sessionStatus.costText)
                if sessionStatus.recognitionApplies {
                    statusRow(loc("Распознавание"), sessionStatus.recognitionLatencyText)
                }
                statusRow(loc("Вопрос → первый текст"), sessionStatus.firstTextLatencyText)
                statusRow(loc("Ошибки"), sessionStatus.errorsText)
                if let spend = sessionStatus.spendText {
                    Text(spend).font(.caption).foregroundStyle(.orange)
                }
                if sessionStatus.hasUnappliedSettings {
                    Text(loc("Есть изменения настроек, ещё не применённые к активной сессии."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if viewModel.currentMode == .answers, let heard = sessionStatus.snapshot.lastHeardText, sessionStatus.recognitionApplies {
                    Text(loc("Распознано:") + " …" + heard)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var captureDescription: String {
        switch viewModel.currentMode {
        case .passive: loc("выключен")
        case .answers: viewModel.phase == .active ? loc("системный звук выбранного приложения") : loc("запускается/останавливается")
        case .recording: loc("системный звук и микрофон")
        }
    }

    private var storageDescription: String {
        let audio = settingsStore.audioStorageEnabled ? loc("WAV в Recording включён") : loc("аудио не сохраняется")
        return loc("пары вопрос-ответ Answers и транскрипты Recording — в локальной истории;") + " " + audio
    }

    private var liveTranscriptList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(transcriptViewModel.entries.enumerated()), id: \.offset) { _, segment in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transcriptViewModel.speakerLabel(for: segment))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(segment.text)
                            .font(.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minHeight: 200)
    }

    private var phaseDescription: String {
        switch viewModel.phase {
        case .idle: loc("Готово")
        case .starting: loc("Запуск…")
        case .active: loc("Активно")
        case .stopping: loc("Остановка…")
        case .failed: loc("Ошибка")
        }
    }
}
