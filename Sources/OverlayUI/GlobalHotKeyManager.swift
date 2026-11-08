import AppKit

public struct HotKeyCombo: Sendable, Equatable, Codable {
    public var keyCode: UInt16
    public var modifierFlags: UInt

    public init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags.rawValue
    }

    public static let forceAnswerNowDefault = HotKeyCombo(keyCode: 36, modifierFlags: .option)

    public static let toggleOverlayDefault = HotKeyCombo(keyCode: 4, modifierFlags: [.option, .command])

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }
}

final class GlobalHotKeyManager {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var handlers: [(combo: HotKeyCombo, action: () -> Void)] = []

    private static let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    func register(_ combo: HotKeyCombo, action: @escaping () -> Void) {
        handlers.append((combo, action))
        installMonitorsIfNeeded()
    }

    func removeAll() {
        handlers.removeAll()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func installMonitorsIfNeeded() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        let eventModifiers = event.modifierFlags.intersection(Self.relevantFlags)
        for entry in handlers where entry.combo.keyCode == event.keyCode && eventModifiers == entry.combo.modifiers {
            entry.action()
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
