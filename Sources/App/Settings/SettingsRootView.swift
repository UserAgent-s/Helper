import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, audio, answers, profile, devices, sessions, accounts, appearance, advanced

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .general: loc("Основное")
        case .audio: loc("Звук")
        case .answers: loc("Ответы")
        case .profile: loc("Профиль и Claude")
        case .devices: loc("Устройства")
        case .sessions: loc("Сессии и данные")
        case .accounts: loc("Ключи и доступы")
        case .appearance: loc("Внешний вид")
        case .advanced: loc("Расширенные")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .audio: "speaker.wave.2"
        case .answers: "text.bubble"
        case .profile: "person.text.rectangle"
        case .devices: "laptopcomputer.and.iphone"
        case .sessions: "tray.full"
        case .accounts: "key"
        case .appearance: "paintbrush"
        case .advanced: "slider.horizontal.3"
        }
    }
}

struct SettingsRootView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var selection: SettingsTab = .general

    var body: some View {
        TabView(selection: $selection) {
            ForEach(SettingsTab.allCases) { tab in
                content(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .task { await viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await viewModel.refreshPermissionStatuses() }
        }
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsTab()
        case .audio: AudioSettingsTab(viewModel: viewModel.audio)
        case .answers: AnswersSettingsTab(viewModel: viewModel)
        case .profile: ProfileSettingsTab(viewModel: viewModel)
        case .devices: DeviceRoleSettingsTab(viewModel: viewModel)
        case .sessions: SessionsDataSettingsTab(viewModel: viewModel)
        case .accounts: AccountsSettingsTab(viewModel: viewModel)
        case .appearance: AppearanceSettingsTab(viewModel: viewModel)
        case .advanced: AdvancedSettingsTab(viewModel: viewModel)
        }
    }
}
