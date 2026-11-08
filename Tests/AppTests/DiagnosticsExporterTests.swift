import Diagnostics
import Domain
import Foundation
import Persistence
import Testing
@testable import UserAgent057

private struct GrantedPermissions: PermissionsChecking {
    func status(for kind: PermissionKind) async -> PermissionStatus { .authorized }
    func request(_ kind: PermissionKind) async -> PermissionStatus { .authorized }
}

@MainActor
@Suite struct DiagnosticsExporterTests {

    private func seededRepositories() async throws -> (SQLiteQuestionAnswerRepository, SQLiteMeetingRepository) {
        let database = SQLiteDatabase(path: ":memory:")
        let answers = SQLiteQuestionAnswerRepository(database: database)
        let meetings = SQLiteMeetingRepository(database: database)
        try await answers.save(QuestionAnswerPair(
            askedAt: Date(),
            sourceAppBundleID: nil,
            questionText: "секретный вопрос",
            contextWindowStartedAt: Date(),
            contextWindowDurationMs: 0,
            triggerKind: .manual,
            answerText: "секретный ответ",
            answerModelID: "gpt-realtime-2.1",
            responseID: "r1",
            status: .completed
        ))
        let meetingID = try await meetings.createMeeting(startedAt: Date(), sourceAppBundleID: nil)
        try await meetings.appendSegment(TranscribedSegment(text: "секретная реплика", startMs: 0, endMs: 10, source: .remote), meetingID: meetingID)
        try await meetings.finish(meetingID: meetingID, endedAt: Date())
        return (answers, meetings)
    }

    @Test func defaultExportHasNoTranscripts() async throws {
        let (answers, meetings) = try await seededRepositories()
        let snapshot = await DiagnosticsExporter.makeSnapshot(
            mode: .passive,
            phase: .idle,
            permissionsChecking: GrantedPermissions(),
            latencyRecorder: InMemoryLatencyRecorder(),
            questionAnswerRepository: answers,
            meetingRepository: meetings
        )
        let json = String(decoding: try DiagnosticsExporter.encodeJSON(snapshot), as: UTF8.self)

        #expect(!snapshot.contentIncluded)
        #expect(snapshot.questionAnswerCount == 1)
        #expect(snapshot.meetingCount == 1)
        #expect(!json.contains("секретн"))
    }

    @Test func optInExportIncludesContent() async throws {
        let (answers, meetings) = try await seededRepositories()
        let snapshot = await DiagnosticsExporter.makeSnapshot(
            mode: .passive,
            phase: .idle,
            permissionsChecking: GrantedPermissions(),
            latencyRecorder: InMemoryLatencyRecorder(),
            questionAnswerRepository: answers,
            meetingRepository: meetings,
            includeContent: true
        )
        let json = String(decoding: try DiagnosticsExporter.encodeJSON(snapshot), as: UTF8.self)
        #expect(json.contains("секретный ответ"))
        #expect(json.contains("секретная реплика"))
    }
}
