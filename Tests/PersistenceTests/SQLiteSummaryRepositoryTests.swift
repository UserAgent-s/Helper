import Foundation
import Testing
import Domain
@testable import Persistence

@Suite struct SQLiteSummaryRepositoryTests {

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingassistant-tests-\(UUID().uuidString).sqlite3")
            .path
    }

    @Test func fetchReturnsNilWhenNoSummaryExists() async throws {
        let path = temporaryDatabasePath()
        let meetingRepository = SQLiteMeetingRepository(path: path)
        let summaryRepository = SQLiteSummaryRepository(path: path)
        let meetingID = try await meetingRepository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)

        let summary = try await summaryRepository.fetch(meetingID: meetingID)
        #expect(summary == nil)
    }

    @Test func savedSummaryRoundTrips() async throws {
        let path = temporaryDatabasePath()
        let meetingRepository = SQLiteMeetingRepository(path: path)
        let summaryRepository = SQLiteSummaryRepository(path: path)
        let meetingID = try await meetingRepository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)

        let summary = MeetingSummary(
            meetingID: meetingID,
            modelID: "gpt-realtime-2.1",
            contentJSON: "{\"points\":[\"a\",\"b\"]}",
            renderedMarkdown: "- a\n- b",
            generatedAt: Date()
        )
        try await summaryRepository.save(summary)

        let fetched = try await summaryRepository.fetch(meetingID: meetingID)
        #expect(fetched?.renderedMarkdown == "- a\n- b")
    }

    @Test func deletingMeetingCascadesToItsSummary() async throws {
        let path = temporaryDatabasePath()
        let meetingRepository = SQLiteMeetingRepository(path: path)
        let summaryRepository = SQLiteSummaryRepository(path: path)
        let meetingID = try await meetingRepository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)
        try await summaryRepository.save(
            MeetingSummary(meetingID: meetingID, modelID: "m", contentJSON: "{}", renderedMarkdown: "x", generatedAt: Date())
        )

        try await meetingRepository.delete(meetingID: meetingID)

        let fetched = try await summaryRepository.fetch(meetingID: meetingID)
        #expect(fetched == nil)
    }
}
