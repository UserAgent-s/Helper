import AppKit

final class AnswerOverlayPanel: NSPanel {
    let style: OverlayStyle

    init(style: OverlayStyle, contentRect: NSRect) {
        self.style = style
        let styleMask: NSWindow.StyleMask = style == .floating
            ? [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable]
            : [.nonactivatingPanel, .borderless, .resizable]
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = style == .floating ? .floating : .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = style == .fullscreen
        backgroundColor = style == .fullscreen ? .black : .clear
        hasShadow = style != .pinned
        animationBehavior = .utilityWindow
        sharingType = .readOnly

        if style == .floating {
            titleVisibility = .hidden
            titlebarAppearsTransparent = true
        }

        switch style {
        case .pinned:
            isMovableByWindowBackground = false
        case .floating:
            isMovableByWindowBackground = true
        case .fullscreen:
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            isMovableByWindowBackground = false
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
