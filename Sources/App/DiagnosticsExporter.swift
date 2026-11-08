import Domain
import Diagnostics
import Foundation

struct DiagnosticsQuestionAnswerEntry: Codable {
    let askedAt: Date
    let sourceAppBundleID: String?
    let questionText: String?
    let answerText: String
    let triggerKind: String
}

struct DiagnosticsMeetingEntry: Codable {
    let startedAt: Date
    let endedAt: Date?
    let sourceAppBundleID: String?
    let transcript: [DiagnosticsTranscriptSegment]
}

struct DiagnosticsTranscriptSegment: Codable {
    let text: String
    let startMs: Int
    let endMs: Int
    let source: String
}

struct DiagnosticsSnapshot: Codable {
    let appVersion: String
    let buildNumber: String
    let currentMode: String
    let currentPhase: String
    let screenRecordingPermission: String
    let microphonePermission: String
    let metricCounts: [String: Int]
    let questionAnswerHistory: [DiagnosticsQuestionAnswerEntry]
    let meetingHistory: [DiagnosticsMeetingEntry]
}

enum DiagnosticsExporter {
    static func makeSnapshot(
        mode: AppMode,
        phase: ModePhase,
        permissionsChecking: any PermissionsChecking,
        latencyRecorder: InMemoryLatencyRecorder,
        questionAnswerRepository: any QuestionAnswerRepository,
        meetingRepository: any MeetingRepository
    ) async -> DiagnosticsSnapshot {
        let bundle = Bundle.main
        let screenRecording = await permissionsChecking.status(for: .screenRecording)
        let microphone = await permissionsChecking.status(for: .microphone)
        let counts = await latencyRecorder.countsByKind()

        let questionAnswerHistory = (try? await questionAnswerRepository.history(limit: 1000))?.map {
            DiagnosticsQuestionAnswerEntry(
                askedAt: $0.askedAt,
                sourceAppBundleID: $0.sourceAppBundleID,
                questionText: $0.questionText,
                answerText: $0.answerText,
                triggerKind: String(describing: $0.triggerKind)
            )
        } ?? []

        let meetingHistory = (try? await meetingRepository.history(limit: 1000, offset: 0))?.map { meeting in
            DiagnosticsMeetingEntry(
                startedAt: meeting.startedAt,
                endedAt: meeting.endedAt,
                sourceAppBundleID: meeting.sourceAppBundleID,
                transcript: meeting.segments.map {
                    DiagnosticsTranscriptSegment(text: $0.text, startMs: $0.startMs, endMs: $0.endMs, source: String(describing: $0.source))
                }
            )
        } ?? []

        return DiagnosticsSnapshot(
            appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            currentMode: String(describing: mode),
            currentPhase: String(describing: phase),
            screenRecordingPermission: String(describing: screenRecording),
            microphonePermission: String(describing: microphone),
            metricCounts: counts,
            questionAnswerHistory: questionAnswerHistory,
            meetingHistory: meetingHistory
        )
    }

    static func encodeJSON(_ snapshot: DiagnosticsSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }
}
