import Domain
import ScreenCaptureKit

struct ShareableContentSnapshot: @unchecked Sendable {
    let hasDisplay: Bool
    let applications: [ShareableApplicationInfo]
    let content: SCShareableContent?
}

protocol ShareableContentProviding: Sendable {
    func snapshot() async throws -> ShareableContentSnapshot
}

struct ScreenCaptureKitShareableContentProvider: ShareableContentProviding {
    func snapshot() async throws -> ShareableContentSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return ShareableContentSnapshot(
            hasDisplay: !content.displays.isEmpty,
            applications: content.applications.map { ShareableApplicationInfo(bundleID: $0.bundleIdentifier, processID: $0.processID) },
            content: content
        )
    }
}

enum SystemAudioCaptureResolver {
    static func resolve(
        scope: SystemAudioScope,
        provider: any ShareableContentProviding,
        permissions: any PermissionsChecking,
        ownBundleID: String
    ) async throws -> (ShareableContentSnapshot, ResolvedSystemAudioPlan) {
        let snapshot: ShareableContentSnapshot
        do {
            snapshot = try await provider.snapshot()
        } catch {
            if await permissions.status(for: .screenRecording) != .authorized {
                throw AudioCaptureError.permissionDenied(.screenRecording)
            }
            throw error
        }
        guard snapshot.hasDisplay else {
            throw AudioCaptureError.noDisplayAvailable
        }
        let resolved = try SystemAudioFilterPlanner.plan(scope: scope, running: snapshot.applications, ownBundleID: ownBundleID)
        return (snapshot, resolved)
    }
}
