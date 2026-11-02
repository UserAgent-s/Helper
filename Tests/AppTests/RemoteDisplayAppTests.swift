import Foundation
import Testing
import Domain
import RemoteDisplay
@testable import MeetingAssistant

@MainActor
@Suite struct RemoteDisplayAppTests {
    @Test func disabledByDefaultAndEnablingStartsConfiguredPorts() async throws {
        let environment = makeIsolatedTestEnvironment()
        let root = CompositionRoot(environment: environment)
        #expect(!root.settingsStore.remoteDisplayEnabled)
        await root.remoteDisplay.applySettings()
        #expect(!root.remoteDisplay.status.isRunning)

        root.settingsStore.remoteDisplayPort = 0
        root.settingsStore.remoteDisplayPort = 51_777
        root.settingsStore.remoteDisplayEnabled = true
        await root.remoteDisplay.applySettings()
        #expect(root.remoteDisplay.startError == nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !root.remoteDisplay.status.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(root.remoteDisplay.status.httpPort == 51_777)
        #expect(root.remoteDisplay.status.webSocketPort == 51_778)
        #expect(root.remoteDisplay.urls.allSatisfy { $0.absoluteString.contains("?t=\(root.settingsStore.remoteDisplayToken)") })

        let (body, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:51777/")!)
        #expect(String(decoding: body, as: UTF8.self).contains("MeetingAssistant"))

        root.settingsStore.remoteDisplayEnabled = false
        await root.remoteDisplay.applySettings()
        let stopDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while root.remoteDisplay.status.isRunning, ContinuousClock.now < stopDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!root.remoteDisplay.status.isRunning)
    }

    @Test func tokenIsStableUntilRegeneratedAndNeverEmpty() {
        let environment = makeIsolatedTestEnvironment()
        let store = AppSettingsStore(defaults: environment.defaults)
        let first = store.remoteDisplayToken
        #expect(first.count >= 16)
        #expect(store.remoteDisplayToken == first)
        store.regenerateRemoteDisplayToken()
        #expect(store.remoteDisplayToken != first)
        #expect(AppSettingsStore(defaults: environment.defaults).remoteDisplayToken == store.remoteDisplayToken)
    }

    @Test func pageResourceIsBundledOrFallsBackSafely() {
        let html = RemoteDisplayCoordinator.loadPageHTML()
        #expect(html.contains(RemoteHTTPResponder.webSocketPortPlaceholder))
        #expect(html.contains("<!doctype html>"))
    }
}
