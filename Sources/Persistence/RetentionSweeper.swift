import Domain
import Foundation

public struct RetentionSweeper: RetentionSweeping {
    private let database: SQLiteDatabase
    private let recordingsDirectory: URL?

    public init(database: SQLiteDatabase, recordingsDirectory: URL?) {
        self.database = database
        self.recordingsDirectory = recordingsDirectory
    }

    @discardableResult
    public func sweep(retentionDays: Int?, now: Date = Date()) async throws -> RetentionSweepReport {
        try await sweep(policy: RetentionPolicy(days: retentionDays), excluding: nil, now: now)
    }

    public func sweep(policy: RetentionPolicy, excluding active: SessionID?, now: Date) async throws -> RetentionSweepReport {
        guard !policy.isNoop else { return RetentionSweepReport() }
        try await database.ensureReady()
        let cutoff = policy.cutoff(now: now).map { ISO8601DateFormatter().string(from: $0) }
        let activeKey = active?.rawValue.uuidString ?? ""
        var report = try await database.sweepTransaction(cutoff: cutoff, activeKey: activeKey, dropScreenTexts: !policy.keepScreenTexts)
        if let recordingsDirectory {
            for id in report.deletedMeetingIDs {
                try? FileManager.default.removeItem(at: recordingsDirectory.appendingPathComponent(id.rawValue.uuidString, isDirectory: true))
            }
        }
        report.deletedMeetingIDs.sort { $0.rawValue.uuidString < $1.rawValue.uuidString }
        return report
    }
}

extension SQLiteDatabase {
    func sweepTransaction(cutoff: String?, activeKey: String, dropScreenTexts: Bool) throws -> RetentionSweepReport {
        var report = RetentionSweepReport()
        try withTransaction {
            if let cutoff {
                let ids = try query(
                    """
                    SELECT id FROM meetings
                    WHERE COALESCE(last_activity_at, ended_at, started_at) < ? AND status != ? AND pinned = 0 AND id != ?
                    """,
                    [.text(cutoff), .text(MeetingStatus.recording.rawValueString), .text(activeKey)],
                    map: { $0.string(0) }
                ).compactMap { $0 }
                for id in ids {
                    try run("DELETE FROM meetings WHERE id = ?", [.text(id)])
                }
                report.deletedMeetingIDs = ids.compactMap(UUID.init(uuidString:)).map(MeetingID.init(rawValue:))
                report.deletedQuestionAnswerCount = try run("DELETE FROM qa_entries WHERE session_id IS NULL AND asked_at < ?", [.text(cutoff)])
            }
            if dropScreenTexts {
                report.deletedScreenContextCount = try run("DELETE FROM screen_contexts WHERE session_id != ?", [.text(activeKey)])
            }
        }
        return report
    }
}
