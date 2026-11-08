import Testing
import Domain
import Foundation
@testable import UserAgent057

private final class StubMeetingRepository: MeetingRepository, @unchecked Sendable {
    let meeting: Meeting

    init(meeting: Meeting) {
        self.meeting = meeting
    }

    func createMeeting(startedAt: Date, sourceAppBundleID: String?) async throws -> MeetingID { meeting.id }
    func appendSegment(_ segment: TranscribedSegment, meetingID: MeetingID) async throws {}
    func finish(meetingID: MeetingID, endedAt: Date) async throws {}
    func reconcileInterruptedMeetings() async throws -> [MeetingID] { [] }
    func fetch(meetingID: MeetingID) async throws -> Meeting {
        guard meetingID == meeting.id else { throw SQLiteStubError.notFound }
        return meeting
    }
    func history(limit: Int, offset: Int) async throws -> [Meeting] { [meeting] }
    func search(query: String) async throws -> [Meeting] { [] }
    func delete(meetingID: MeetingID) async throws {}
    func deleteAll() async throws {}
}

private enum SQLiteStubError: Error { case notFound }

@Suite struct DesktopMeetingExporterTests {

    @Test func exportWritesMarkdownTranscriptIntoDatedFolder() async throws {
        let meetingID = MeetingID()
        let startedAt = DateComponents(calendar: .init(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 9, day: 21, hour: 14, minute: 0).date!
        let segments = [
            TranscribedSegment(text: "Привет", startMs: 0, endMs: 1000, source: .local),
            TranscribedSegment(text: "Здравствуйте", startMs: 1000, endMs: 2000, source: .remote),
        ]
        let meeting = Meeting(id: meetingID, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60), status: .completed, segments: segments)
        let repository = StubMeetingRepository(meeting: meeting)

        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let exporter = DesktopMeetingExporter(meetingRepository: repository, baseDirectory: tempBase)

        await exporter.export(meetingID: meetingID)

        let expectedFolder = tempBase.appendingPathComponent(DesktopMeetingExporter.folderName(for: startedAt), isDirectory: true)
        let transcriptURL = expectedFolder.appendingPathComponent("transcript.md")
        #expect(FileManager.default.fileExists(atPath: transcriptURL.path))

        let contents = try String(contentsOf: transcriptURL, encoding: .utf8)
        #expect(contents.contains("Привет"))
        #expect(contents.contains("Здравствуйте"))
    }

    @Test func exportCopiesExistingAudioFilesAlongsideTranscript() async throws {
        let meetingID = MeetingID()
        let startedAt = Date()
        let meeting = Meeting(id: meetingID, startedAt: startedAt, endedAt: startedAt, status: .completed, segments: [])
        let repository = StubMeetingRepository(meeting: meeting)

        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let audioSource = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempBase)
            try? FileManager.default.removeItem(at: audioSource)
        }
        try FileManager.default.createDirectory(at: audioSource, withIntermediateDirectories: true)
        try Data("fake wav".utf8).write(to: audioSource.appendingPathComponent("mic.wav"))

        let exporter = DesktopMeetingExporter(meetingRepository: repository, baseDirectory: tempBase)
        await exporter.export(meetingID: meetingID, audioSourceDirectory: audioSource)

        let expectedFolder = tempBase.appendingPathComponent(DesktopMeetingExporter.folderName(for: startedAt), isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: expectedFolder.appendingPathComponent("mic.wav").path))
        #expect(!FileManager.default.fileExists(atPath: expectedFolder.appendingPathComponent("system.wav").path))
    }
}
