import AppKit
import Domain
import Foundation
import Observation

struct RunningApplicationEntry: Hashable, Sendable {
    let name: String
    let bundleID: String
}

struct MicrophoneOption: Hashable, Identifiable {
    let uid: String
    let name: String
    let isEnabled: Bool

    var id: String { uid }
}

@MainActor
@Observable
final class AudioSettingsViewModel {
    enum SourceMode: Hashable {
        case wholeSystem
        case chrome
        case application
    }

    private let store: any PreferredAudioSourceStoring
    private let catalog: (any AudioDeviceCataloging)?
    private let settingsStore: AppSettingsStore
    private let runningApplicationsProvider: @MainActor () -> [RunningApplicationEntry]
    private let onMicrophonePlanChanged: @MainActor () -> Void
    private var levelsTask: Task<Void, Never>?

    private(set) var scope: SystemAudioScope = .defaultScope
    private(set) var microphoneSelection: MicrophoneSelection = .systemDefaultExcludingContinuity
    private(set) var inputDevices: [AudioDeviceInfo] = []
    private(set) var currentRoute: OutputRoute = .unknown
    private(set) var levels: [AudioSourceKind: AudioLevel] = [:]
    private(set) var runningApplications: [RunningApplicationEntry] = []

    init(
        store: any PreferredAudioSourceStoring,
        catalog: (any AudioDeviceCataloging)?,
        settingsStore: AppSettingsStore,
        levels: AsyncStream<AudioLevel>? = nil,
        runningApplicationsProvider: @escaping @MainActor () -> [RunningApplicationEntry] = AudioSettingsViewModel.workspaceApplications,
        onMicrophonePlanChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.onMicrophonePlanChanged = onMicrophonePlanChanged
        self.store = store
        self.catalog = catalog
        self.settingsStore = settingsStore
        self.runningApplicationsProvider = runningApplicationsProvider
        if let levels {
            levelsTask = Task { [weak self] in
                for await level in levels {
                    self?.levels[level.kind] = level
                }
            }
        }
    }

    var sourceMode: SourceMode {
        switch scope {
        case .wholeSystem: .wholeSystem
        case .application(let bundleID, _) where bundleID == SystemAudioScope.chromeBundleID: .chrome
        case .application: .application
        }
    }

    var selectedApplicationBundleID: String? {
        scope.targetApplicationBundleID
    }

    var exclusions: [String] {
        if case .wholeSystem(let excluded) = scope { return excluded }
        return []
    }

    var outputRoutePolicy: OutputRoutePolicy {
        get { settingsStore.outputRoutePolicy }
        set {
            settingsStore.outputRoutePolicy = newValue
            onMicrophonePlanChanged()
        }
    }

    var voiceProcessingActive: Bool {
        MicrophoneProfile.me.voiceProcessing(route: currentRoute, policy: outputRoutePolicy)
    }

    var meChannelEnabled: Bool {
        get { settingsStore.meChannelEnabled }
        set { settingsStore.meChannelEnabled = newValue }
    }

    var echoRisk: Bool {
        OutputRouteClassifier.echoRisk(currentRoute, policy: outputRoutePolicy)
    }

    var microphoneOptions: [MicrophoneOption] {
        inputDevices.map { MicrophoneOption(uid: $0.uid, name: $0.name, isEnabled: !$0.transport.isContinuity) }
    }

    var selectedMicrophoneUID: String {
        if case .device(let uid) = microphoneSelection { return uid }
        return ""
    }

    func load() async {
        scope = await store.systemAudioScope()
        microphoneSelection = await store.microphoneSelection()
        refreshDevices()
    }

    func refreshDevices() {
        inputDevices = (catalog?.devices() ?? []).filter(\.hasInput).sorted { $0.name < $1.name }
        currentRoute = OutputRouteClassifier.classify(catalog?.defaultOutputDevice())
        runningApplications = runningApplicationsProvider()
    }

    func selectWholeSystem() async {
        await save(scope: .wholeSystem(excludingBundleIDs: exclusions))
    }

    func selectChromePreset() async {
        await save(scope: .chromeOnlyPreset)
    }

    func selectApplication(bundleID: String) async {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await save(scope: .application(bundleID: trimmed, fallbackToWholeSystem: true))
    }

    func excludeApplication(bundleID: String) async {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !exclusions.contains(trimmed) else { return }
        await save(scope: .wholeSystem(excludingBundleIDs: exclusions + [trimmed]))
    }

    func removeExclusion(bundleID: String) async {
        await save(scope: .wholeSystem(excludingBundleIDs: exclusions.filter { $0 != bundleID }))
    }

    func selectMicrophone(uid: String) async {
        let selection: MicrophoneSelection
        if uid.isEmpty {
            selection = .systemDefaultExcludingContinuity
        } else if let device = inputDevices.first(where: { $0.uid == uid }), device.transport.isContinuity {
            return
        } else {
            selection = .device(uid: uid)
        }
        microphoneSelection = selection
        await store.setMicrophoneSelection(selection)
    }

    func applicationName(for bundleID: String) -> String {
        runningApplications.first { $0.bundleID == bundleID }?.name ?? bundleID
    }

    static func meterFraction(_ level: AudioLevel?, now: Date = Date()) -> Double {
        guard let level, now.timeIntervalSince(level.at) < 1.5 else { return 0 }
        return Double(min(1, max(0, (level.rmsDBFS + 60) / 60)))
    }

    private func save(scope newScope: SystemAudioScope) async {
        scope = newScope
        await store.setSystemAudioScope(newScope)
    }

    static func workspaceApplications() -> [RunningApplicationEntry] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return RunningApplicationEntry(name: name, bundleID: bundleID)
            }
            .sorted { $0.name < $1.name }
    }
}
