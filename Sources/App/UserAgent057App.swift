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
        windowController = AnswerOverlayWindowController(viewModel: root.answerOverlayViewModel)
        menuBarController = MenuBarController(
            overlayViewModel: root.answerOverlayViewModel,
            modeViewModel: root.modeViewModel,
            navigationState: root.navigationState
        )
    }
}
