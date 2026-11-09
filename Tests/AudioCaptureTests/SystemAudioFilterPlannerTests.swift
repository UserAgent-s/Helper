import Foundation
import Testing
@testable import AudioCapture
@testable import Domain

private let ownBundleID = "com.local.UserAgent057"

private func app(_ bundleID: String, _ pid: pid_t = 1) -> ShareableApplicationInfo {
    ShareableApplicationInfo(bundleID: bundleID, processID: pid)
}

private struct FakeShareableContentProvider: ShareableContentProviding {
    var hasDisplay = true
    var applications: [ShareableApplicationInfo] = []
    var error: (any Error)?

    func snapshot() async throws -> ShareableContentSnapshot {
        if let error { throw error }
        return ShareableContentSnapshot(hasDisplay: hasDisplay, applications: applications, content: nil)
    }
}

private struct FixedPermissions: PermissionsChecking {
    let screenRecording: PermissionStatus

    func status(for kind: PermissionKind) async -> PermissionStatus { screenRecording }
    func request(_ kind: PermissionKind) async -> PermissionStatus { screenRecording }
}

private struct ContentUnavailable: Error {}

@Suite struct SystemAudioFilterPlannerTests {

    @Test func wholeSystemExcludesOwnBundle() throws {
        let resolved = try SystemAudioFilterPlanner.plan(scope: .defaultScope, running: [app("com.google.Chrome")], ownBundleID: ownBundleID)
        #expect(resolved.plan == .display(excludingBundleIDs: [ownBundleID]))
        #expect(resolved.effectiveScope == .defaultScope)
        #expect(resolved.notice == nil)
    }

    @Test func wholeSystemHonorsUserExclusions() throws {
        let scope = SystemAudioScope.wholeSystem(excludingBundleIDs: ["com.spotify.client", ownBundleID])
        let resolved = try SystemAudioFilterPlanner.plan(scope: scope, running: [], ownBundleID: ownBundleID)
        #expect(resolved.plan == .display(excludingBundleIDs: ["com.spotify.client", ownBundleID]))
    }

    @Test func chromePresentGivesApplicationPlan() throws {
        let resolved = try SystemAudioFilterPlanner.plan(
            scope: .chromeOnlyPreset,
            running: [app("com.apple.Safari"), app("com.google.Chrome")],
            ownBundleID: ownBundleID
        )
        #expect(resolved.plan == .applications(bundleIDs: ["com.google.Chrome"]))
        #expect(resolved.effectiveScope == .chromeOnlyPreset)
        #expect(resolved.notice == nil)
    }

    @Test func chromeHelpersIncluded() throws {
        let resolved = try SystemAudioFilterPlanner.plan(
            scope: .chromeOnlyPreset,
            running: [app("com.google.Chrome.helper.renderer"), app("com.google.Chrome"), app("com.google.Chrome.helper"), app("com.google.Chromeish")],
            ownBundleID: ownBundleID
        )
        #expect(resolved.plan == .applications(bundleIDs: ["com.google.Chrome", "com.google.Chrome.helper", "com.google.Chrome.helper.renderer"]))
    }

    @Test func chromeMissingFallsBackWithNotice() throws {
        let resolved = try SystemAudioFilterPlanner.plan(
            scope: .chromeOnlyPreset,
            running: [app("com.google.Chrome.helper"), app("us.zoom.xos")],
            ownBundleID: ownBundleID
        )
        #expect(resolved.plan == .display(excludingBundleIDs: [ownBundleID]))
        #expect(resolved.effectiveScope == .defaultScope)
        #expect(resolved.notice == .fellBackToWholeSystem(missingBundleID: "com.google.Chrome"))
    }

    @Test func applicationWithoutFallbackThrows() {
        #expect(throws: AudioCaptureError.targetApplicationNotFound("us.zoom.xos")) {
            try SystemAudioFilterPlanner.plan(
                scope: .application(bundleID: "us.zoom.xos", fallbackToWholeSystem: false),
                running: [app("com.google.Chrome")],
                ownBundleID: ownBundleID
            )
        }
    }

    @Test func noDisplayThrowsNoDisplayAvailable() async {
        await #expect(throws: AudioCaptureError.noDisplayAvailable) {
            _ = try await SystemAudioCaptureResolver.resolve(
                scope: .defaultScope,
                provider: FakeShareableContentProvider(hasDisplay: false),
                permissions: FixedPermissions(screenRecording: .authorized),
                ownBundleID: ownBundleID
            )
        }
    }

    @Test func permissionDeniedMapsToPermissionError() async {
        await #expect(throws: AudioCaptureError.permissionDenied(.screenRecording)) {
            _ = try await SystemAudioCaptureResolver.resolve(
                scope: .defaultScope,
                provider: FakeShareableContentProvider(error: ContentUnavailable()),
                permissions: FixedPermissions(screenRecording: .denied),
                ownBundleID: ownBundleID
            )
        }
    }

    @Test func resolverFallsBackWhenChromeNotRunning() async throws {
        let (_, resolved) = try await SystemAudioCaptureResolver.resolve(
            scope: .chromeOnlyPreset,
            provider: FakeShareableContentProvider(applications: [app("com.apple.Safari")]),
            permissions: FixedPermissions(screenRecording: .authorized),
            ownBundleID: ownBundleID
        )
        #expect(resolved.notice == .fellBackToWholeSystem(missingBundleID: "com.google.Chrome"))
    }
}
