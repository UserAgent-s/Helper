import Domain
import Foundation

public final class SQLiteMeetingRepository: MeetingRepository, Sendable {
    private let connection: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        connection = database
    }

    public convenience init(path: String) {
        self.init(database: SQLiteDatabase(path: path))
    }

    public func createMeeting(startedAt: Date, sourceAppBundleID: String?) async throws -> MeetingID {
        try await connection.ensureReady()
        let id = MeetingID()
        let now = ISO8601DateFormatter().string(from: startedAt)
        try await connection.run(
            """
            INSERT INTO meetings (id, title, source_bundle_id, started_at, ended_at, status, created_at, updated_at)
            VALUES (?, NULL, ?, ?, NULL, ?, ?, ?)
            """,
            [
                .text(id.rawValue.uuidString),
                sourceAppBundleID.map(SQLiteValue.text) ?? .null,
                .text(now),
                .text(MeetingStatus.recording.rawValueString),
                .text(now),
                .text(now),
            ]
        )
        return id
    }

    public func appendSegment(_ segment: TranscribedSegment, meetingID: MeetingID) async throws {
        try await connection.ensureReady()
        try await connection.run(
            """
            INSERT INTO utterances (id, meeting_id, source, started_ms, ended_ms, text, language, confidence, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(UUID().uuidString),
                .text(meetingID.rawValue.uuidString),
                .text(segment.source.rawValueString),
                .int(segment.startMs),
                .int(segment.endMs),
                .text(segment.text),
                segment.language.map(SQLiteValue.text) ?? .null,
                segment.confidence.map(SQLiteValue.double) ?? .null,
                .text(ISO8601DateFormatter().string(from: Date())),
            ]
        )
    }

    public func finish(meetingID: MeetingID, endedAt: Date) async throws {
        try await connection.ensureReady()
        try await connection.run(
            "UPDATE meetings SET ended_at = ?, status = ?, updated_at = ? WHERE id = ?",
            [
                .text(ISO8601DateFormatter().string(from: endedAt)),
                .text(MeetingStatus.completed.rawValueString),
                .text(ISO8601DateFormatter().string(from: endedAt)),
                .text(meetingID.rawValue.uuidString),
            ]
        )
    }

    public func reconcileInterruptedMeetings() async throws -> [MeetingID] {
        try await connection.ensureReady()
        let ids = try await connection.query(
            "SELECT id FROM meetings WHERE status = ?",
            [.text(MeetingStatus.recording.rawValueString)],
            map: { row in row.string(0) }
        ).compactMap { $0 }

        guard !ids.isEmpty else { return [] }
        try await connection.run(
            "UPDATE meetings SET status = ?, updated_at = ? WHERE status = ?",
            [
                .text(MeetingStatus.interrupted.rawValueString),
                .text(ISO8601DateFormatter().string(from: Date())),
                .text(MeetingStatus.recording.rawValueString),
            ]
        )
        return ids.compactMap { UUID(uuidString: $0) }.map { MeetingID(rawValue: $0) }
    }

    public func fetch(meetingID: MeetingID) async throws -> Meeting {
        try await connection.ensureReady()
        let rows = try await connection.query(
            "SELECT id, title, source_bundle_id, started_at, ended_at, status FROM meetings WHERE id = ?",
            [.text(meetingID.rawValue.uuidString)],
            map: Self.meetingRowMapper
        )
        guard let partial = rows.first else {
            throw SQLitePersistenceError.notFound("meeting \(meetingID.rawValue)")
        }
        let segments = try await fetchSegments(meetingID: meetingID)
        return partial.withSegments(segments)
    }

    public func history(limit: Int, offset: Int) async throws -> [Meeting] {
        try await connection.ensureReady()
        let partials = try await connection.query(
            "SELECT id, title, source_bundle_id, started_at, ended_at, status FROM meetings ORDER BY started_at DESC LIMIT ? OFFSET ?",
            [.int(limit), .int(offset)],
            map: Self.meetingRowMapper
        )
        var meetings: [Meeting] = []
        for partial in partials {
            let segments = try await fetchSegments(meetingID: partial.id)
            meetings.append(partial.withSegments(segments))
        }
        return meetings
    }

    public func search(query: String) async throws -> [Meeting] {
        try await connection.ensureReady()
        let matchingMeetingIDs = try await connection.query(
            """
            SELECT DISTINCT meeting_id FROM utterances
            WHERE rowid IN (SELECT rowid FROM utterances_fts WHERE utterances_fts MATCH ?)
            """,
            [.text(Self.ftsQuery(from: query))],
            map: { row in row.string(0) }
        ).compactMap { $0 }

        var meetings: [Meeting] = []
        for idString in matchingMeetingIDs {
            guard let uuid = UUID(uuidString: idString) else { continue }
            meetings.append(try await fetch(meetingID: MeetingID(rawValue: uuid)))
        }
        return meetings
    }

    public func delete(meetingID: MeetingID) async throws {
        try await connection.ensureReady()
        try await connection.run("DELETE FROM meetings WHERE id = ?", [.text(meetingID.rawValue.uuidString)])
    }

    public func deleteAll() async throws {
        try await connection.ensureReady()
        try await connection.run("DELETE FROM meetings")
    }

    private func fetchSegments(meetingID: MeetingID) async throws -> [TranscribedSegment] {
        try await connection.query(
            "SELECT source, started_ms, ended_ms, text, language, confidence FROM utterances WHERE meeting_id = ? ORDER BY started_ms",
            [.text(meetingID.rawValue.uuidString)],
            map: { row in
                TranscribedSegment(
                    text: row.string(3) ?? "",
                    startMs: row.int(1) ?? 0,
                    endMs: row.int(2) ?? 0,
                    source: TranscriptSource(rawValueString: row.string(0) ?? "") ?? .remote,
                    language: row.string(4),
                    confidence: row.double(5)
                )
            }
        )
    }

    private static func ftsQuery(from raw: String) -> String {
        let sanitized = raw.replacingOccurrences(of: "\"", with: "")
        return "\"\(sanitized)\""
    }

    private struct PartialMeeting {
        let id: MeetingID
        let title: String?
        let sourceAppBundleID: String?
        let startedAt: Date
        let endedAt: Date?
        let status: MeetingStatus

        func withSegments(_ segments: [TranscribedSegment]) -> Meeting {
            Meeting(
                id: id,
                title: title,
                sourceAppBundleID: sourceAppBundleID,
                startedAt: startedAt,
                endedAt: endedAt,
                status: status,
                segments: segments
            )
        }
    }

    private static func meetingRowMapper(_ row: SQLiteRow) -> PartialMeeting {
        let idString = row.string(0) ?? ""
        let startedAtString = row.string(3) ?? ""
        return PartialMeeting(
            id: MeetingID(rawValue: UUID(uuidString: idString) ?? UUID()),
            title: row.string(1),
            sourceAppBundleID: row.string(2),
            startedAt: ISO8601DateFormatter().date(from: startedAtString) ?? Date(),
            endedAt: row.string(4).flatMap { ISO8601DateFormatter().date(from: $0) },
            status: MeetingStatus(rawValueString: row.string(5) ?? "") ?? .failed
        )
    }
}

enum SQLitePersistenceError: Error, Sendable, Equatable {
    case notFound(String)
}

extension MeetingStatus {
    var rawValueString: String {
        switch self {
        case .recording: "recording"
        case .completed: "completed"
        case .interrupted: "interrupted"
        case .failed: "failed"
        }
    }

    init?(rawValueString: String) {
        switch rawValueString {
        case "recording": self = .recording
        case "completed": self = .completed
        case "interrupted": self = .interrupted
        case "failed": self = .failed
        default: return nil
        }
    }
}

extension TranscriptSource {
    var rawValueString: String {
        switch self {
        case .remote: "remote"
        case .local: "local"
        }
    }

    init?(rawValueString: String) {
        switch rawValueString {
        case "remote": self = .remote
        case "local": self = .local
        default: return nil
        }
    }
}
