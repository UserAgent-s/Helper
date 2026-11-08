import Foundation
import Testing
import Domain
@testable import Persistence

@Suite struct SQLiteMeetingRepositoryTests {

    @Test func migratesFromZeroAndIsIdempotentOnReopen() async throws {
        let repository = SQLiteMeetingRepository(path: ":memory:")
        let id = try await repository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)
        let fetched = try await repository.fetch(meetingID: id)
        #expect(fetched.status == .recording)
    }

    @Test func createFinishAndFetchRoundTrips() async throws {
        let repository = SQLiteMeetingRepository(path: ":memory:")
        let startedAt = Date(timeIntervalSince1970: 1_000_000)
        let id = try await repository.createMeeting(startedAt: startedAt, sourceAppBundleID: "com.zoom.xos")

        try await repository.appendSegment(
            TranscribedSegment(text: "Привет", startMs: 0, endMs: 500, source: .local),
            meetingID: id
        )
        try await repository.appendSegment(
            TranscribedSegment(text: "Добрый день", startMs: 500, endMs: 1200, source: .remote),
            meetingID: id
        )

        let endedAt = startedAt.addingTimeInterval(120)
        try await repository.finish(meetingID: id, endedAt: endedAt)

        let meeting = try await repository.fetch(meetingID: id)
        #expect(meeting.status == .completed)
        #expect(meeting.sourceAppBundleID == "com.zoom.xos")
        #expect(meeting.segments.map(\.text) == ["Привет", "Добрый день"])
        #expect(meeting.segments.map(\.source) == [.local, .remote])
    }

    @Test func historyOrdersNewestFirstAndRespectsLimitOffset() async throws {
        let repository = SQLiteMeetingRepository(path: ":memory:")
        let first = try await repository.createMeeting(startedAt: Date(timeIntervalSince1970: 100), sourceAppBundleID: nil)
        let second = try await repository.createMeeting(startedAt: Date(timeIntervalSince1970: 200), sourceAppBundleID: nil)
        _ = try await repository.createMeeting(startedAt: Date(timeIntervalSince1970: 300), sourceAppBundleID: nil)

        let page = try await repository.history(limit: 2, offset: 1)
        #expect(page.count == 2)
        #expect(page.map(\.id) == [second, first])
    }

    @Test func searchFindsMeetingByUtteranceText() async throws {
        let repository = SQLiteMeetingRepository(path: ":memory:")
        let id = try await repository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)
        try await repository.appendSegment(
            TranscribedSegment(text: "обсуждаем бюджет квартала", startMs: 0, endMs: 500, source: .remote),
            meetingID: id
        )
        let otherID = try await repository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)
        try await repository.appendSegment(
            TranscribedSegment(text: "погода сегодня хорошая", startMs: 0, endMs: 500, source: .remote),
            meetingID: otherID
        )

        let results = try await repository.search(query: "бюджет")
        #expect(results.map(\.id) == [id])
    }

    @Test func deleteCascadesToUtterances() async throws {
        let repository = SQLiteMeetingRepository(path: ":memory:")
        let id = try await repository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)
        try await repository.appendSegment(
            TranscribedSegment(text: "удалится вместе с митингом", startMs: 0, endMs: 100, source: .local),
            meetingID: id
        )

        try await repository.delete(meetingID: id)

        await #expect(throws: (any Error).self) {
            _ = try await repository.fetch(meetingID: id)
        }
    }

    @Test func deleteAllClearsEveryMeeting() async throws {
        let repository = SQLiteMeetingRepository(path: ":memory:")
        _ = try await repository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)
        _ = try await repository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)

        try await repository.deleteAll()

        let remaining = try await repository.history(limit: 100, offset: 0)
        #expect(remaining.isEmpty)
    }

    @Test func reconcileInterruptedMeetingsMarksOnlyRecordingRows() async throws {
        let repository = SQLiteMeetingRepository(path: ":memory:")
        let stillRecording = try await repository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)
        let finishedID = try await repository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)
        try await repository.finish(meetingID: finishedID, endedAt: Date())

        let interruptedIDs = try await repository.reconcileInterruptedMeetings()

        #expect(interruptedIDs == [stillRecording])
        let reconciled = try await repository.fetch(meetingID: stillRecording)
        #expect(reconciled.status == .interrupted)
        let untouched = try await repository.fetch(meetingID: finishedID)
        #expect(untouched.status == .completed)
    }
}
