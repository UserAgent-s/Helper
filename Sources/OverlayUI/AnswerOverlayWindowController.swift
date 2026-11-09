import AppKit
import SwiftUI
import Observation
import OverlayReducer

@MainActor
final class AnswerOverlayWindowController: NSObject {
    private var panel: AnswerOverlayPanel?
    private var hosting: NSHostingView<AnswerOverlayContentView>?
    private let viewModel: AnswerOverlayViewModel
    private let preferences: OverlayPreferencesStore
    private let overlaySwitch: OverlaySwitch
    private let hotKeyManager: GlobalHotKeyManager
    private var manuallyHidden = false
    private var appliedStyle: OverlayStyle
    private var appliedFontFamily: OverlayFontFamily
    private var escMonitor: Any?
    private var switchObserver: UUID?

    var hasPanel: Bool { panel != nil }

    init(
        viewModel: AnswerOverlayViewModel,
        preferences: OverlayPreferencesStore = OverlayPreferencesStore(),
        overlaySwitch: OverlaySwitch? = nil,
        registersHotKeys: Bool = true,
        hotKeyBackend: HotKeyBackend? = nil
    ) {
        hotKeyManager = GlobalHotKeyManager(backend: hotKeyBackend)
        self.viewModel = viewModel
        self.preferences = preferences
        self.overlaySwitch = overlaySwitch ?? OverlaySwitch(preferences: preferences)
        appliedStyle = preferences.style
        appliedFontFamily = preferences.fontFamily
        super.init()

        if registersHotKeys {
            hotKeyManager.register(preferences.forceAnswerHotKey) { [weak viewModel] in
                viewModel?.forceAnswerNow()
            }
            hotKeyManager.register(preferences.toggleOverlayHotKey) { [weak self] in
                self?.toggleManualVisibility()
            }
        }

        switchObserver = self.overlaySwitch.observe { [weak self] enabled in
            self?.applyEnabled(enabled)
        }
        applyEnabled(self.overlaySwitch.isEnabled)
        observeState()
    }

    func tearDown() {
        if let switchObserver {
            overlaySwitch.removeObserver(switchObserver)
        }
        switchObserver = nil
        hotKeyManager.removeAll()
        destroyPanel()
    }

    private func applyEnabled(_ enabled: Bool) {
        if enabled {
            guard panel == nil else { return }
            appliedStyle = preferences.style
            appliedFontFamily = preferences.fontFamily
            buildPanel()
            syncVisibility()
            resizeToFitContent()
        } else {
            destroyPanel()
        }
    }

    private func buildPanel() {
        let panel = Self.makePanel(style: appliedStyle)
        panel.alphaValue = preferences.opacity
        let hosting = NSHostingView(rootView: AnswerOverlayContentView(viewModel: viewModel, style: appliedStyle, fontFamily: appliedFontFamily) { [weak self] _ in
            self?.copyFinalAnswerToPasteboard()
        })
        self.panel = panel
        self.hosting = hosting
        attachHosting()
        installEscMonitorIfNeeded()
    }

    private func destroyPanel() {
        removeEscMonitor()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hosting = nil
    }

    func forceAnswerNow() {
        viewModel.forceAnswerNow()
    }

    private func toggleManualVisibility() {
        guard panel != nil else { return }
        manuallyHidden.toggle()
        syncVisibility()
    }

    private func observeState() {
        withObservationTracking {
            _ = viewModel.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncVisibility()
                self?.observeState()
                DispatchQueue.main.async {
                    self?.resizeToFitContent()
                }
            }
        }
    }

    private func rebuildPanelIfPreferencesChanged() {
        guard let current = panel else { return }
        let desiredStyle = preferences.style
        let desiredFontFamily = preferences.fontFamily
        guard desiredStyle != appliedStyle || desiredFontFamily != appliedFontFamily else { return }

        let wasVisible = current.isVisible
        destroyPanel()
        appliedStyle = desiredStyle
        appliedFontFamily = desiredFontFamily
        buildPanel()

        if wasVisible, let panel {
            resizeToFitContent()
            panel.orderFrontRegardless()
        }
    }

    private func attachHosting() {
        guard let panel, let hosting else { return }
        switch appliedStyle {
        case .fullscreen:
            hosting.sizingOptions = []
            hosting.autoresizingMask = [.width, .height]
        case .pinned, .floating:
            hosting.sizingOptions = [.intrinsicContentSize]
        }
        panel.contentView = hosting
    }

    private func installEscMonitorIfNeeded() {
        guard appliedStyle == .pinned || appliedStyle == .fullscreen else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.toggleManualVisibility()
                return nil
            }
            return event
        }
    }

    private func removeEscMonitor() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
        }
        escMonitor = nil
    }

    private func resizeToFitContent() {
        rebuildPanelIfPreferencesChanged()

        guard let panel, let hosting, let screen = NSScreen.main else { return }

        switch appliedStyle {
        case .fullscreen:
            panel.setFrame(screen.frame, display: false)
            hosting.frame = panel.contentView?.bounds ?? .zero
        case .pinned:
            let fitting = hosting.fittingSize
            guard fitting.width > 1, fitting.height > 1 else { return }
            panel.setContentSize(fitting)
            let origin = OverlayGeometry.pinnedOrigin(for: panel.frame.size, screenFrame: screen.frame)
            panel.setFrameOrigin(origin)
        case .floating:
            let fitting = hosting.fittingSize
            guard fitting.width > 1, fitting.height > 1 else { return }
            panel.setContentSize(fitting)
            positionPanelIfNeeded()
        }
    }

    private func syncVisibility() {
        rebuildPanelIfPreferencesChanged()
        guard let panel else { return }

        let shouldShow = viewModel.state.visibility != .hidden && !manuallyHidden
        if shouldShow {
            if appliedStyle != .fullscreen { positionPanelIfNeeded() }
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func positionPanelIfNeeded() {
        guard let panel, let screen = NSScreen.main else { return }

        if appliedStyle == .pinned {
            let origin = OverlayGeometry.pinnedOrigin(for: panel.frame.size, screenFrame: screen.frame)
            panel.setFrameOrigin(origin)
            return
        }

        let frame = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 16

        let origin: CGPoint
        switch preferences.position {
        case .topRight:
            origin = CGPoint(x: frame.maxX - size.width - margin, y: frame.maxY - size.height - margin)
        case .topCenter:
            origin = CGPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - margin)
        case .bottomRight:
            origin = CGPoint(x: frame.maxX - size.width - margin, y: frame.minY + margin)
        case .custom:
            origin = preferences.customOrigin ?? CGPoint(x: frame.maxX - size.width - margin, y: frame.maxY - size.height - margin)
        }
        panel.setFrameOrigin(origin)
    }

    private func copyFinalAnswerToPasteboard() {
        guard let finalText = viewModel.copyFinalAnswer() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(finalText, forType: .string)
    }

    private static func makePanel(style: OverlayStyle) -> AnswerOverlayPanel {
        AnswerOverlayPanel(style: style, contentRect: NSRect(x: 0, y: 0, width: 420, height: 120))
    }
}
