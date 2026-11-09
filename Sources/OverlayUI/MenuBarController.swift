import AppKit
import Domain
import Observation
import OverlayReducer

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let overlayViewModel: AnswerOverlayViewModel
    private let modeViewModel: ModeSwitcherViewModel
    private let sessionViewModel: SessionControlViewModel?
    private let navigationState: AppNavigationState
    private let overlaySwitch: OverlaySwitch

    private let statusLabelItem: NSMenuItem
    private let sessionItem: NSMenuItem
    private let starItem: NSMenuItem
    private let momentItem: NSMenuItem
    private let passiveItem: NSMenuItem
    private let answersItem: NSMenuItem
    private let recordingItem: NSMenuItem
    private let forceAnswerItem: NSMenuItem
    private let historyItem: NSMenuItem
    private let settingsItem: NSMenuItem
    private let pairingItem: NSMenuItem
    private let overlayItem: NSMenuItem
    private let languageMenuItem: NSMenuItem
    private let quitItem: NSMenuItem
    private var languageOptionItems: [AppLanguage: NSMenuItem] = [:]

    init(overlayViewModel: AnswerOverlayViewModel, modeViewModel: ModeSwitcherViewModel, sessionViewModel: SessionControlViewModel? = nil, navigationState: AppNavigationState, overlaySwitch: OverlaySwitch) {
        self.overlayViewModel = overlayViewModel
        self.modeViewModel = modeViewModel
        self.sessionViewModel = sessionViewModel
        self.navigationState = navigationState
        self.overlaySwitch = overlaySwitch

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusLabelItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sessionItem = NSMenuItem(title: "", action: #selector(Self.toggleSessionTapped), keyEquivalent: "")
        starItem = NSMenuItem(title: "", action: #selector(Self.starLastAnswerTapped), keyEquivalent: "")
        momentItem = NSMenuItem(title: "", action: #selector(Self.markMomentTapped), keyEquivalent: "")
        passiveItem = NSMenuItem(title: "", action: #selector(Self.selectPassiveTapped), keyEquivalent: "")
        answersItem = NSMenuItem(title: "", action: #selector(Self.selectAnswersTapped), keyEquivalent: "")
        recordingItem = NSMenuItem(title: "", action: #selector(Self.selectRecordingTapped), keyEquivalent: "")
        forceAnswerItem = NSMenuItem(title: "", action: #selector(Self.forceAnswerNowTapped), keyEquivalent: "")
        historyItem = NSMenuItem(title: "", action: #selector(Self.openHistoryTapped), keyEquivalent: "")
        settingsItem = NSMenuItem(title: "", action: #selector(Self.openSettingsTapped), keyEquivalent: "")
        pairingItem = NSMenuItem(title: "", action: #selector(Self.openPairingTapped), keyEquivalent: "")
        overlayItem = NSMenuItem(title: "", action: #selector(Self.toggleOverlayTapped), keyEquivalent: "")
        languageMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        quitItem = NSMenuItem(title: "", action: #selector(Self.quitTapped), keyEquivalent: "q")
        super.init()

        statusLabelItem.isEnabled = false
        sessionItem.setAccessibilityIdentifier("menu.session.toggle")
        starItem.setAccessibilityIdentifier("menu.session.star")
        momentItem.setAccessibilityIdentifier("menu.session.moment")
        [sessionItem, starItem, momentItem, passiveItem, answersItem, recordingItem, forceAnswerItem, historyItem, settingsItem, pairingItem, overlayItem, quitItem].forEach { $0.target = self }

        let languageSubmenu = NSMenu()
        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: language.displayName, action: #selector(Self.languageTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language
            languageSubmenu.addItem(item)
            languageOptionItems[language] = item
        }
        languageMenuItem.submenu = languageSubmenu

        let menu = NSMenu()
        menu.addItem(statusLabelItem)
        menu.addItem(.separator())
        if sessionViewModel != nil {
            menu.addItem(sessionItem)
            menu.addItem(starItem)
            menu.addItem(momentItem)
            menu.addItem(.separator())
        }
        menu.addItem(passiveItem)
        menu.addItem(answersItem)
        menu.addItem(recordingItem)
        menu.addItem(.separator())
        menu.addItem(forceAnswerItem)
        menu.addItem(overlayItem)
        menu.addItem(.separator())
        menu.addItem(historyItem)
        menu.addItem(settingsItem)
        menu.addItem(pairingItem)
        menu.addItem(languageMenuItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu

        observeOverlayState()
        observeModeState()
        observeLanguage()
        observeOverlaySwitch()
        observeSessionState()
    }

    @objc private func toggleSessionTapped() { Task { await sessionViewModel?.toggle() } }
    @objc private func starLastAnswerTapped() { Task { await sessionViewModel?.starLastAnswer() } }
    @objc private func markMomentTapped() { Task { await sessionViewModel?.markMoment() } }

    @objc private func selectPassiveTapped() { modeViewModel.select(.passive) }
    @objc private func selectAnswersTapped() { modeViewModel.select(.answers) }
    @objc private func selectRecordingTapped() { modeViewModel.select(.recording) }
    @objc private func forceAnswerNowTapped() { overlayViewModel.forceAnswerNow() }
    @objc private func openHistoryTapped() { navigationState.isShowingHistory = true }
    @objc private func openSettingsTapped() { navigationState.isShowingSettings = true }
    @objc private func openPairingTapped() { navigationState.requestPairing() }
    @objc private func toggleOverlayTapped() { overlaySwitch.setEnabled(!overlaySwitch.isEnabled) }
    @objc private func quitTapped() { modeViewModel.terminate() }

    @objc private func languageTapped(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? AppLanguage else { return }
        LocalizationCenter.shared.setLanguage(language)
    }

    private func syncModeState() {
        let mode = modeViewModel.currentMode
        let phase = modeViewModel.phase

        statusLabelItem.title = loc("Текущий режим:") + " \(modeLabel(mode)) — \(phaseLabel(phase))"
        statusItem.button?.title = ""
        statusItem.button?.image = coloredSymbolImage(for: mode)

        passiveItem.state = mode == .passive ? .on : .off
        answersItem.state = mode == .answers ? .on : .off
        recordingItem.state = mode == .recording ? .on : .off
    }

    private func observeSessionState() {
        guard let sessionViewModel else { return }
        withObservationTracking {
            _ = sessionViewModel.state
            _ = sessionViewModel.isBusy
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncSessionState()
                self?.observeSessionState()
            }
        }
        syncSessionState()
    }

    private func syncSessionState() {
        guard let sessionViewModel else { return }
        let active = sessionViewModel.isActive
        sessionItem.title = active ? loc("Остановить сессию") : loc("Начать сессию")
        sessionItem.state = active ? .on : .off
        sessionItem.isEnabled = !sessionViewModel.isBusy && !isFinalizing(sessionViewModel.state)
        starItem.title = loc("Отметить последний ответ ★")
        momentItem.title = loc("Отметить момент")
        starItem.isEnabled = active
        momentItem.isEnabled = active
    }

    private func isFinalizing(_ state: SessionState) -> Bool {
        if case .finalizing = state { return true }
        return false
    }

    private func syncStaticTitles() {
        passiveItem.title = loc("Пассивный")
        answersItem.title = loc("Ответы")
        recordingItem.title = loc("Запись митинга")
        forceAnswerItem.title = loc("Ответить сейчас")
        historyItem.title = loc("Открыть историю")
        settingsItem.title = loc("Настройки")
        pairingItem.title = loc("Подключить устройство…")
        overlayItem.title = loc("Оверлей на этом Mac")
        languageMenuItem.title = loc("Язык")
        quitItem.title = loc("Завершить UserAgent057")
        syncModeState()
        syncSessionState()
    }

    private func modeLabel(_ mode: AppMode) -> String {
        switch mode {
        case .passive: loc("Пассивный")
        case .answers: loc("Ответы")
        case .recording: loc("Запись")
        }
    }

    private func phaseLabel(_ phase: ModePhase) -> String {
        switch phase {
        case .idle: loc("готово")
        case .starting: loc("запуск")
        case .active: loc("активно")
        case .stopping: loc("остановка")
        case .failed: loc("ошибка")
        }
    }

    private func symbolName(for mode: AppMode) -> String {
        switch mode {
        case .passive: "moon.zzz.fill"
        case .answers: "bubble.left.and.text.bubble.right.fill"
        case .recording: "record.circle.fill"
        }
    }

    private func tintColor(for mode: AppMode) -> NSColor {
        switch mode {
        case .passive: .systemGray
        case .answers: .systemRed
        case .recording: .systemOrange
        }
    }

    private func coloredSymbolImage(for mode: AppMode) -> NSImage? {
        guard let baseImage = NSImage(systemSymbolName: symbolName(for: mode), accessibilityDescription: modeLabel(mode)) else { return nil }
        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular, scale: .medium)
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [tintColor(for: mode)])
        let config = sizeConfig.applying(colorConfig)
        guard let colored = baseImage.withSymbolConfiguration(config) else { return nil }
        colored.isTemplate = false
        colored.size = NSSize(width: 18, height: 18)
        return colored
    }

    private func observeModeState() {
        withObservationTracking {
            _ = modeViewModel.currentMode
            _ = modeViewModel.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncModeState()
                self?.observeModeState()
            }
        }
        syncModeState()
    }

    private func observeOverlayState() {
        withObservationTracking {
            _ = overlayViewModel.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncEnabledState()
                self?.observeOverlayState()
            }
        }
        syncEnabledState()
    }

    private func observeOverlaySwitch() {
        withObservationTracking {
            _ = overlaySwitch.isEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncOverlayItem()
                self?.observeOverlaySwitch()
            }
        }
        syncOverlayItem()
    }

    private func syncOverlayItem() {
        overlayItem.state = overlaySwitch.isEnabled ? .on : .off
    }

    private func observeLanguage() {
        withObservationTracking {
            _ = LocalizationCenter.shared.language
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncStaticTitles()
                self?.syncLanguageCheckmarks()
                self?.observeLanguage()
            }
        }
        syncStaticTitles()
        syncLanguageCheckmarks()
    }

    private func syncLanguageCheckmarks() {
        let current = LocalizationCenter.shared.language
        for (language, item) in languageOptionItems {
            item.state = language == current ? .on : .off
        }
    }

    private func syncEnabledState() {
        let visibility = overlayViewModel.state.visibility
        forceAnswerItem.isEnabled = visibility != .manualResponsePending && visibility != .streaming && visibility != .hidden
    }
}
