import Foundation
import Testing
import Domain
@testable import Persistence

@Suite struct SQLiteFailureInjectionTests {

    @Test func unopenableDatabasePathThrowsRatherThanCrashing() async throws {
        let unwritableDirectoryAsFilePath = FileManager.default.temporaryDirectory.path
        let repository = SQLiteMeetingRepository(path: unwritableDirectoryAsFilePath)

        await #expect(throws: (any Error).self) {
            _ = try await repository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)
        }
    }

    @Test func failedRepositoryCallDoesNotCorruptSubsequentOperationsOnAWorkingDatabase() async throws {
        let workingRepository = SQLiteMeetingRepository(path: ":memory:")
        let id = try await workingRepository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)
        let meeting = try await workingRepository.fetch(meetingID: id)
        #expect(meeting.status == .recording)
    }
}
