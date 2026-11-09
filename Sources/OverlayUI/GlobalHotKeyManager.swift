import AppKit
import Carbon.HIToolbox

public struct HotKeyCombo: Sendable, Equatable, Hashable, Codable {
    public var keyCode: UInt16
    public var modifierFlags: UInt

    public init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags.intersection(Self.relevantFlags).rawValue
    }

    public static let forceAnswerNowDefault = HotKeyCombo(keyCode: UInt16(kVK_Return), modifierFlags: .option)

    public static let toggleOverlayDefault = HotKeyCombo(keyCode: UInt16(kVK_ANSI_H), modifierFlags: [.option, .command])

    public static let toggleSessionDefault = HotKeyCombo(keyCode: UInt16(kVK_ANSI_S), modifierFlags: [.control, .option, .command])

    public static let starLastAnswerDefault = HotKeyCombo(keyCode: UInt16(kVK_ANSI_B), modifierFlags: [.control, .option, .command])

    static let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags).intersection(Self.relevantFlags) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

enum HotKeyAction: String, CaseIterable, Sendable {
    case answerNow
    case toggleOverlay
    case toggleSession
    case starLastAnswer
    case toggleScreen

    var defaultCombo: HotKeyCombo? {
        switch self {
        case .answerNow: .forceAnswerNowDefault
        case .toggleOverlay: .toggleOverlayDefault
        case .toggleSession: .toggleSessionDefault
        case .starLastAnswer: .starLastAnswerDefault
        case .toggleScreen: nil
        }
    }
}

enum HotKeyRegistrationResult: Equatable, Sendable {
    case registered(UInt32)
    case duplicate
    case unavailable(Int32)
}

@MainActor
protocol HotKeyBackend: AnyObject {
    func install(dispatch: @escaping @MainActor (UInt32) -> Void) -> Bool
    func uninstall()
    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Int32
    func unregister(id: UInt32)
}

@MainActor
final class GlobalHotKeyManager {
    private let backend: HotKeyBackend
    private var installed = false
    private var nextID: UInt32 = 1
    private var entries: [UInt32: (combo: HotKeyCombo, action: @MainActor () -> Void)] = [:]

    init(backend: HotKeyBackend? = nil) {
        self.backend = backend ?? CarbonHotKeyBackend()
    }

    var registeredCombos: [HotKeyCombo] { entries.keys.sorted().compactMap { entries[$0]?.combo } }

    @discardableResult
    func register(_ combo: HotKeyCombo, action: @escaping @MainActor () -> Void) -> HotKeyRegistrationResult {
        guard !entries.values.contains(where: { $0.combo == combo }) else { return .duplicate }
        if !installed {
            installed = backend.install { [weak self] id in self?.dispatch(id: id) }
            guard installed else { return .unavailable(-1) }
        }
        let id = nextID
        let status = backend.register(keyCode: UInt32(combo.keyCode), modifiers: combo.carbonModifiers, id: id)
        guard status == 0 else { return .unavailable(status) }
        nextID += 1
        entries[id] = (combo, action)
        return .registered(id)
    }

    func unregister(_ combo: HotKeyCombo) {
        guard let id = entries.first(where: { $0.value.combo == combo })?.key else { return }
        backend.unregister(id: id)
        entries[id] = nil
    }

    func removeAll() {
        for id in entries.keys { backend.unregister(id: id) }
        entries.removeAll()
        if installed { backend.uninstall() }
        installed = false
    }

    func dispatch(id: UInt32) {
        entries[id]?.action()
    }
}

@MainActor
final class CarbonHotKeyBackend: HotKeyBackend {
    static let signature: OSType = 0x55413537

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var dispatch: (@MainActor (UInt32) -> Void)?

    func install(dispatch: @escaping @MainActor (UInt32) -> Void) -> Bool {
        guard handlerRef == nil else { return true }
        self.dispatch = dispatch
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == CarbonHotKeyBackend.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let id = hotKeyID.id
                let backend = Unmanaged<CarbonHotKeyBackend>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { backend.dispatch?(id) }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        return status == noErr
    }

    func uninstall() {
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        dispatch = nil
    }

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Int32 {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            OptionBits(0),
            &ref
        )
        if status == noErr, let ref { hotKeyRefs[id] = ref }
        return status
    }

    func unregister(id: UInt32) {
        guard let ref = hotKeyRefs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }

    isolated deinit {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
