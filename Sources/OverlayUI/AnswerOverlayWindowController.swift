import AppKit
import SwiftUI
import Observation
import OverlayReducer

@MainActor
final class AnswerOverlayWindowController: NSObject {
    private var panel: AnswerOverlayPanel
    private var hosting: NSHostingView<AnswerOverlayContentView>
    private let viewModel: AnswerOverlayViewModel
    private let preferences: OverlayPreferencesStore
    private let hotKeyManager = GlobalHotKeyManager()
    private var manuallyHidden = false
    private var appliedStyle: OverlayStyle
    private var appliedFontFamily: OverlayFontFamily
    private var escMonitor: Any?

    init(viewModel: AnswerOverlayViewModel, preferences: OverlayPreferencesStore = OverlayPreferencesStore()) {
        self.viewModel = viewModel
        self.preferences = preferences
        appliedStyle = preferences.style
        appliedFontFamily = preferences.fontFamily
        panel = Self.makePanel(style: appliedStyle)
        hosting = NSHostingView(rootView: AnswerOverlayContentView(viewModel: viewModel, style: appliedStyle, fontFamily: appliedFontFamily) { _ in })
        super.init()

        panel.alphaValue = preferences.opacity

        hosting.rootView = AnswerOverlayContentView(viewModel: viewModel, style: appliedStyle, fontFamily: appliedFontFamily) { [weak self] _ in
            self?.copyFinalAnswerToPasteboard()
        }
        attachHosting()
        installEscMonitorIfNeeded()

        hotKeyManager.register(preferences.forceAnswerHotKey) { [weak viewModel] in
            viewModel?.forceAnswerNow()
        }
        hotKeyManager.register(preferences.toggleOverlayHotKey) { [weak self] in
            self?.toggleManualVisibility()
        }

        observeState()
        resizeToFitContent()
    }

    func forceAnswerNow() {
        viewModel.forceAnswerNow()
    }

    private func toggleManualVisibility() {
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
        let desiredStyle = preferences.style
        let desiredFontFamily = preferences.fontFamily
        guard desiredStyle != appliedStyle || desiredFontFamily != appliedFontFamily else { return }

        let wasVisible = panel.isVisible
        removeEscMonitor()
        panel.orderOut(nil)

        appliedStyle = desiredStyle
        appliedFontFamily = desiredFontFamily
        panel = Self.makePanel(style: appliedStyle)
        panel.alphaValue = preferences.opacity
        hosting = NSHostingView(rootView: AnswerOverlayContentView(viewModel: viewModel, style: appliedStyle, fontFamily: appliedFontFamily) { [weak self] _ in
            self?.copyFinalAnswerToPasteboard()
        })
        attachHosting()
        installEscMonitorIfNeeded()

        if wasVisible {
            resizeToFitContent()
            panel.orderFrontRegardless()
        }
    }

    private func attachHosting() {
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

        guard let screen = NSScreen.main else { return }

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
        guard let screen = NSScreen.main else { return }

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
