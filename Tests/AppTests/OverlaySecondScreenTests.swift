import Testing
import Domain
import Foundation
@testable import UserAgent057

private func temporaryDefaults() -> UserDefaults {
    let name = "UserAgent057Tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private final class EmptyMeetingRepository: MeetingRepository, @unchecked Sendable {
    let meeting: Meeting

    init(meeting: Meeting) {
        self.meeting = meeting
    }

    func createMeeting(startedAt: Date, sourceAppBundleID: String?) async throws -> MeetingID { meeting.id }
    func appendSegment(_ segment: TranscribedSegment, meetingID: MeetingID, capturedAt: Date?) async throws {}
    func finish(meetingID: MeetingID, endedAt: Date) async throws {}
    func reconcileInterruptedMeetings() async throws -> [MeetingID] { [] }
    func fetch(meetingID: MeetingID) async throws -> Meeting { meeting }
    func history(limit: Int, offset: Int) async throws -> [Meeting] { [meeting] }
    func search(query: String) async throws -> [Meeting] { [] }
    func delete(meetingID: MeetingID) async throws {}
    func deleteAll() async throws {}
}

@MainActor
@Suite(.serialized) struct OverlaySecondScreenTests {
    @Test func overlayIsEnabledByDefaultAndPersists() {
        let defaults = temporaryDefaults()
        let overlaySwitch = OverlaySwitch(preferences: OverlayPreferencesStore(defaults: defaults))
        #expect(overlaySwitch.isEnabled)

        var seen: [Bool] = []
        overlaySwitch.observe { seen.append($0) }
        overlaySwitch.setEnabled(false)
        overlaySwitch.setEnabled(false)
        #expect(seen == [false])
        #expect(OverlayPreferencesStore(defaults: defaults).isOverlayEnabled == false)
        #expect(OverlaySwitch(preferences: OverlayPreferencesStore(defaults: defaults)).isEnabled == false)
    }

    @Test func controllerCreatesNoPanelWhenOverlayDisabled() {
        let root = CompositionRoot()
        let preferences = OverlayPreferencesStore(defaults: temporaryDefaults())
        preferences.isOverlayEnabled = false
        let overlaySwitch = OverlaySwitch(preferences: preferences)
        let controller = AnswerOverlayWindowController(
            viewModel: root.answerOverlayViewModel,
            preferences: preferences,
            overlaySwitch: overlaySwitch,
            registersHotKeys: false
        )
        defer { controller.tearDown() }
        #expect(controller.hasPanel == false)

        overlaySwitch.setEnabled(true)
        #expect(controller.hasPanel)

        overlaySwitch.setEnabled(false)
        #expect(controller.hasPanel == false)
    }

    @Test func controllerCreatesPanelWhenOverlayEnabled() {
        let root = CompositionRoot()
        let preferences = OverlayPreferencesStore(defaults: temporaryDefaults())
        let controller = AnswerOverlayWindowController(
            viewModel: root.answerOverlayViewModel,
            preferences: preferences,
            overlaySwitch: OverlaySwitch(preferences: preferences),
            registersHotKeys: false
        )
        defer { controller.tearDown() }
        #expect(controller.hasPanel)
    }

    @Test func noDesktopWriteByDefault() async throws {
        let settings = AppSettingsStore(defaults: temporaryDefaults())
        #expect(settings.meetingAutoExportEnabled == false)

        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let meeting = Meeting(id: MeetingID(), startedAt: Date(), endedAt: Date(), status: .completed, segments: [])
        let exporter = MeetingFolderExporter(meetingRepository: EmptyMeetingRepository(meeting: meeting), baseDirectory: base)
        let autoExporter = MeetingAutoExporter(
            isEnabled: { settings.meetingAutoExportEnabled },
            exporter: exporter,
            recordingsDirectory: base.appendingPathComponent("recordings", isDirectory: true)
        )

        #expect(await autoExporter.meetingFinished(meeting.id) == false)
        #expect(FileManager.default.fileExists(atPath: base.path) == false)

        settings.meetingAutoExportEnabled = true
        #expect(await autoExporter.meetingFinished(meeting.id))
        let folder = base.appendingPathComponent(MeetingFolderExporter.folderName(for: meeting.startedAt), isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path))
    }

    @Test func exportsAndLogsLiveOutsideDesktopAndTmp() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let exports = AppFileLocations.exportsDirectory(documents: home.appendingPathComponent("Documents", isDirectory: true))
        #expect(exports.path == "/Users/someone/Documents/UserAgent057/Exports")
        let log = AppFileLocations.realtimeDiagnosticsLog(library: home.appendingPathComponent("Library", isDirectory: true))
        #expect(log.path == "/Users/someone/Library/Logs/UserAgent057/realtime_diag.log")
    }
}
