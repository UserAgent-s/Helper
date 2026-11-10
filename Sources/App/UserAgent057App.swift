import SwiftUI
import Domain
import AppKit

@main
struct UserAgent057App: App {
    @NSApplicationDelegateAdaptor(UserAgent057AppDelegate.self) private var appDelegate
    @State private var root = CompositionRoot()
    @State private var overlayCoordinator: OverlayCoordinator?

    var body: some Scene {
        WindowGroup {
            ModeSwitcherView(
                viewModel: root.modeViewModel,
                transcriptViewModel: root.recordingTranscriptViewModel,
                historyViewModel: root.historyViewModel,
                settingsViewModel: root.settingsViewModel,
                settingsStore: root.settingsStore,
                permissionsChecking: root.permissionsChecking,
                latencyRecording: root.latencyRecording,
                navigationState: root.navigationState,
                secretStoring: root.secretStoring,
                whisperKitTranscribing: root.whisperKitTranscribing,
                questionAnswerRepository: root.questionAnswerRepository,
                meetingRepository: root.meetingRepository
            )
                .onAppear {
                    if overlayCoordinator == nil {
                        overlayCoordinator = OverlayCoordinator(root: root)
                        appDelegate.modeCoordinator = root.modeCoordinator
                    }
                }
        }
        .windowResizability(.contentSize)

        .commands {
            PairingCommands(navigationState: root.navigationState)
        }

        Window(loc("Настройки"), id: SettingsWindow.id) {
            SettingsRootView(viewModel: root.settingsViewModel, navigationState: root.navigationState)
        }
        .windowResizability(.contentMinSize)

        Window(loc("Подключить устройство"), id: PairingWindow.id) {
            CompanionPairingView(viewModel: root.companionPairingViewModel, navigationState: root.navigationState)
        }
        .windowResizability(.contentSize)
    }
}

enum SettingsWindow {
    static let id = "settings"
}

struct PairingCommands: Commands {
    var navigationState: AppNavigationState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button(loc("Подключить устройство…")) {
                navigationState.markPairingRequested()
                openWindow(id: PairingWindow.id)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

@MainActor
final class UserAgent057AppDelegate: NSObject, NSApplicationDelegate {
    var modeCoordinator: ModeCoordinator?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let modeCoordinator else { return .terminateNow }
        Task { @MainActor in
            await modeCoordinator.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
@Observable
final class OverlayCoordinator {
    private let windowController: AnswerOverlayWindowController
    private let menuBarController: MenuBarController

    init(root: CompositionRoot) {
        let preferences = OverlayPreferencesStore()
        windowController = AnswerOverlayWindowController(viewModel: root.answerOverlayViewModel, preferences: preferences, overlaySwitch: root.overlaySwitch)
        menuBarController = MenuBarController(
            overlayViewModel: root.answerOverlayViewModel,
            modeViewModel: root.modeViewModel,
            sessionViewModel: root.sessionControlViewModel,
            navigationState: root.navigationState,
            overlaySwitch: root.overlaySwitch
        )
        root.sessionControlViewModel.registerHotKeys(on: windowController, preferences: preferences)
        let screenTrigger = root.screenTrigger
        _ = windowController.registerHotKey(preferences.screenCaptureHotKey) {
            Task { await screenTrigger.trigger(kind: .auto, ask: false) }
        }
        _ = windowController.registerHotKey(preferences.screenAskHotKey) {
            Task { await screenTrigger.trigger(kind: .auto, ask: true) }
        }
    }
}
