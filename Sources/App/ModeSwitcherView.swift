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
    private(set) var captureNoticeText: String?
    private(set) var outputRoute: OutputRoute = .unknown
    private let outputRoutePolicy: @MainActor () -> OutputRoutePolicy

    var echoWarning: String? {
        guard currentMode != .passive, OutputRouteClassifier.echoRisk(outputRoute, policy: outputRoutePolicy()) else { return nil }
        return loc("Динамики: возможна утечка эха собеседника в микрофон")
    }

    var lastError: String? {
        guard let failureReason else { return nil }
        switch failureReason {
        case .permissionDenied(.screenRecording):
            return loc("Нет доступа к записи экрана. Откройте Настройки и предоставьте разрешение Screen Recording.")
        case .permissionDenied(.microphone):
            return loc("Нет доступа к микрофону. Откройте Настройки и предоставьте разрешение Microphone.")
        case .targetApplicationNotRunning(let bundleID):
            return loc("Приложение") + " «\(bundleID)» " + loc("не запущено, а переход на весь звук Mac для него выключен. Откройте приложение или выберите «Весь звук Mac» в настройках «Звук».")
        case .noControllerRegistered:
            return loc("Этот режим сейчас недоступен.")
        case .unknown:
            return loc("Не удалось запустить режим. Попробуйте ещё раз.")
        }
    }

    init(
        modeCoordinator: ModeCoordinator,
        captureNotices: AsyncStream<CaptureNotice>? = nil,
        outputRoutes: AsyncStream<OutputRoute>? = nil,
        outputRoutePolicy: @escaping @MainActor () -> OutputRoutePolicy = { .auto }
    ) {
        self.modeCoordinator = modeCoordinator
        self.outputRoutePolicy = outputRoutePolicy
        if let outputRoutes {
            Task { [weak self] in
                for await route in outputRoutes {
                    self?.outputRoute = route
                }
            }
        }
        if let captureNotices {
            Task { [weak self] in
                for await notice in captureNotices {
                    self?.captureNoticeText = AnswerOverlayContentView.text(for: notice)
                }
            }
        }
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
        if state.mode == .passive {
            captureNoticeText = nil
        }
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
    var secretStoring: any SecretStoring
    var whisperKitTranscribing: WhisperKitTranscribing
    var questionAnswerRepository: any QuestionAnswerRepository
    var meetingRepository: any MeetingRepository
    @Environment(\.openWindow) private var openWindow
    @State private var isConfirmingContentExport = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("UserAgent057")
                    .font(.title2)
                Spacer()
                Button(loc("Диагностика")) {
                    if settingsStore.diagnosticsIncludeContentOptIn {
                        isConfirmingContentExport = true
                    } else {
                        exportDiagnostics(includeContent: false)
                    }
                }
                .confirmationDialog(loc("Включить в экспорт стенограммы и Q&A?"), isPresented: $isConfirmingContentExport) {
                    Button(loc("С содержимым")) { exportDiagnostics(includeContent: true) }
                    Button(loc("Без содержимого")) { exportDiagnostics(includeContent: false) }
                    Button(loc("Отмена"), role: .cancel) {}
                } message: {
                    Text(loc("Файл будет содержать тексты реплик и ответов. Не отправляйте его, если встречи конфиденциальны."))
                }
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

            if let warning = viewModel.echoWarning {
                Text(warning)
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            if let notice = viewModel.captureNoticeText {
                Text(notice)
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            if let error = viewModel.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if viewModel.currentMode == .recording {
                liveTranscriptList
            }
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: viewModel.currentMode == .recording ? 420 : 160)
        .sheet(isPresented: Binding(get: { navigationState.isShowingHistory }, set: { navigationState.isShowingHistory = $0 })) {
            HistoryView(viewModel: historyViewModel)
        }
        .onChange(of: navigationState.isShowingSettings) { _, isShowing in
            guard isShowing else { return }
            openWindow(id: SettingsWindow.id)
            NSApp.activate()
            navigationState.isShowingSettings = false
        }
        .sheet(isPresented: Binding(get: { navigationState.isShowingOnboarding }, set: { navigationState.isShowingOnboarding = $0 })) {
            OnboardingView(secretStoring: secretStoring, whisperKitTranscribing: whisperKitTranscribing, permissionsChecking: permissionsChecking) {
                settingsStore.onboardingCompleted = true
                navigationState.isShowingOnboarding = false
            }
        }
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
        case .answers: loc("Answers: системный звук уходит в OpenAI Realtime API")
        case .recording: loc("Recording: аудио обрабатывается только локально")
        }
    }

    private func exportDiagnostics(includeContent: Bool) {
        Task {
            let snapshot = await DiagnosticsExporter.makeSnapshot(
                mode: viewModel.currentMode,
                phase: viewModel.phase,
                permissionsChecking: permissionsChecking,
                latencyRecorder: latencyRecording,
                questionAnswerRepository: questionAnswerRepository,
                meetingRepository: meetingRepository,
                includeContent: includeContent,
                outputRoute: viewModel.outputRoute
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
