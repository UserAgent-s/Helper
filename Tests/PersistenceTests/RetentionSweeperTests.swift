import Foundation
import Testing
import Domain
@testable import Persistence

@Suite struct RetentionSweeperTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pair(askedAt: Date) -> QuestionAnswerPair {
        QuestionAnswerPair(
            askedAt: askedAt,
            sourceAppBundleID: nil,
            questionText: "старый вопрос",
            contextWindowStartedAt: askedAt,
            contextWindowDurationMs: 0,
            triggerKind: .automatic,
            answerText: "ответ",
            answerModelID: "gpt-realtime-2.1",
            responseID: UUID().uuidString,
            status: .completed
        )
    }

    @Test func deletesOlderThanRetentionWithAudioAndFTS() async throws {
        let database = SQLiteDatabase(path: ":memory:")
        let meetings = SQLiteMeetingRepository(database: database)
        let answers = SQLiteQuestionAnswerRepository(database: database)
        let recordings = FileManager.default.temporaryDirectory.appendingPathComponent("ua057-rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: recordings) }

        let old = try await meetings.createMeeting(startedAt: now.addingTimeInterval(-40 * 86_400), sourceAppBundleID: nil)
        try await meetings.appendSegment(TranscribedSegment(text: "давняя реплика", startMs: 0, endMs: 10, source: .remote), meetingID: old)
        try await meetings.finish(meetingID: old, endedAt: now.addingTimeInterval(-40 * 86_400 + 60))
        let fresh = try await meetings.createMeeting(startedAt: now.addingTimeInterval(-1 * 86_400), sourceAppBundleID: nil)
        try await meetings.finish(meetingID: fresh, endedAt: now)
        let stillRecording = try await meetings.createMeeting(startedAt: now.addingTimeInterval(-50 * 86_400), sourceAppBundleID: nil)
        try await answers.save(pair(askedAt: now.addingTimeInterval(-40 * 86_400)))
        try await answers.save(pair(askedAt: now.addingTimeInterval(-86_400)))

        let oldAudio = recordings.appendingPathComponent(old.rawValue.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: oldAudio, withIntermediateDirectories: true)
        try Data([1, 2]).write(to: oldAudio.appendingPathComponent("system.wav"))

        let report = try await RetentionSweeper(database: database, recordingsDirectory: recordings).sweep(retentionDays: 30, now: now)

        #expect(report.deletedMeetingIDs == [old])
        #expect(report.deletedQuestionAnswerCount == 1)
        let remaining = try await meetings.history(limit: 10, offset: 0).map(\.id)
        #expect(Set(remaining) == Set([fresh, stillRecording]))
        #expect(try await meetings.search(query: "давняя").isEmpty)
        #expect(try await answers.history(limit: 10).count == 1)
        #expect(!FileManager.default.fileExists(atPath: oldAudio.path))
        let orphanUtterances = try await database.query("SELECT COUNT(*) FROM utterances", map: { $0.int(0) ?? -1 })
        #expect(orphanUtterances == [0])
    }

    @Test func keepsEverythingWhenRetentionIsNil() async throws {
        let database = SQLiteDatabase(path: ":memory:")
        let meetings = SQLiteMeetingRepository(database: database)
        let old = try await meetings.createMeeting(startedAt: now.addingTimeInterval(-400 * 86_400), sourceAppBundleID: nil)
        try await meetings.finish(meetingID: old, endedAt: now.addingTimeInterval(-400 * 86_400))

        let report = try await RetentionSweeper(database: database, recordingsDirectory: nil).sweep(retentionDays: nil, now: now)

        #expect(report == RetentionSweepReport())
        #expect(try await meetings.history(limit: 10, offset: 0).count == 1)
    }
}
