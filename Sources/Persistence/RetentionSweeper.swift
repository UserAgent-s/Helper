import Domain
import Foundation

public struct RetentionSweepReport: Sendable, Equatable {
    public var deletedMeetingIDs: [MeetingID]
    public var deletedQuestionAnswerCount: Int

    public init(deletedMeetingIDs: [MeetingID] = [], deletedQuestionAnswerCount: Int = 0) {
        self.deletedMeetingIDs = deletedMeetingIDs
        self.deletedQuestionAnswerCount = deletedQuestionAnswerCount
    }
}

public struct RetentionSweeper: Sendable {
    private let database: SQLiteDatabase
    private let recordingsDirectory: URL?

    public init(database: SQLiteDatabase, recordingsDirectory: URL?) {
        self.database = database
        self.recordingsDirectory = recordingsDirectory
    }

    @discardableResult
    public func sweep(retentionDays: Int?, now: Date = Date()) async throws -> RetentionSweepReport {
        guard let retentionDays, retentionDays > 0 else { return RetentionSweepReport() }
        let cutoffDate = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let cutoff = ISO8601DateFormatter().string(from: cutoffDate)
        try await database.ensureReady()
        let meetingIDs = try await database.query(
            "SELECT id FROM meetings WHERE started_at < ? AND status != ?",
            [.text(cutoff), .text(MeetingStatus.recording.rawValueString)],
            map: { $0.string(0) }
        ).compactMap { $0.flatMap(UUID.init(uuidString:)) }.map(MeetingID.init(rawValue:))
        let deletedQA = try await database.sweepTransaction(cutoff: cutoff, meetingIDs: meetingIDs.map(\.rawValue.uuidString))
        if let recordingsDirectory {
            for id in meetingIDs {
                try? FileManager.default.removeItem(at: recordingsDirectory.appendingPathComponent(id.rawValue.uuidString, isDirectory: true))
            }
        }
        return RetentionSweepReport(deletedMeetingIDs: meetingIDs, deletedQuestionAnswerCount: deletedQA)
    }
}

extension SQLiteDatabase {
    func sweepTransaction(cutoff: String, meetingIDs: [String]) throws -> Int {
        var deletedQA = 0
        try withTransaction {
            for id in meetingIDs {
                try run("DELETE FROM meetings WHERE id = ?", [.text(id)])
            }
            deletedQA = try run("DELETE FROM qa_entries WHERE asked_at < ?", [.text(cutoff)])
        }
        return deletedQA
    }
}
