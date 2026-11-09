import Domain
import Foundation

final class MeetingAutoExporter: Sendable {
    private let isEnabled: @Sendable () -> Bool
    private let exporter: MeetingFolderExporter
    private let recordingsDirectory: URL

    init(isEnabled: @escaping @Sendable () -> Bool, exporter: MeetingFolderExporter, recordingsDirectory: URL) {
        self.isEnabled = isEnabled
        self.exporter = exporter
        self.recordingsDirectory = recordingsDirectory
    }

    @discardableResult
    func meetingFinished(_ meetingID: MeetingID) async -> Bool {
        guard isEnabled() else { return false }
        let audioDirectory = recordingsDirectory.appendingPathComponent(meetingID.rawValue.uuidString, isDirectory: true)
        await exporter.export(meetingID: meetingID, audioSourceDirectory: audioDirectory)
        return true
    }
}
