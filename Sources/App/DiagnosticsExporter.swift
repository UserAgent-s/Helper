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

struct DiagnosticsAnswerSession: Codable {
    let provider: String?
    let configuredModel: String?
    let modelIsCustom: Bool?
    let servedModel: String?
    let triggerMode: String?
    let answerLength: String?
    let expertAreas: [String]?
    let status: String
    let usage: ProviderUsage
    let responsesWithUsage: Int
    let responsesWithoutUsage: Int
    let estimatedCostUSD: Double?
    let pricingSource: String?
    let pricingVerifiedOn: String?
    let recognitionLatencyP50Ms: Int?
    let recognitionLatencyP95Ms: Int?
    let questionToFirstTextP50Ms: Int?
    let questionToFirstTextP95Ms: Int?
    let errorCounts: [String: Int]
    let lastErrorCode: String?
    let reconnects: Int
    let spendLimitUSD: Double?
    let spendState: String
}

struct DiagnosticsSnapshot: Codable {
    let appVersion: String
    let buildNumber: String
    let currentMode: String
    let currentPhase: String
    let screenRecordingPermission: String
    let microphonePermission: String
    let metricCounts: [String: Int]
    let answerSession: DiagnosticsAnswerSession
    let includesConversationContent: Bool
    let questionAnswerHistory: [DiagnosticsQuestionAnswerEntry]?
    let meetingHistory: [DiagnosticsMeetingEntry]?
}

enum DiagnosticsExporter {
    static func makeSnapshot(
        mode: AppMode,
        phase: ModePhase,
        permissionsChecking: any PermissionsChecking,
        latencyRecorder: InMemoryLatencyRecorder,
        telemetry: SessionTelemetrySnapshot,
        includeContent: Bool,
        questionAnswerRepository: any QuestionAnswerRepository,
        meetingRepository: any MeetingRepository
    ) async -> DiagnosticsSnapshot {
        let bundle = Bundle.main
        let screenRecording = await permissionsChecking.status(for: .screenRecording)
        let microphone = await permissionsChecking.status(for: .microphone)
        let counts = await latencyRecorder.countsByKind()

        var questionAnswerHistory: [DiagnosticsQuestionAnswerEntry]?
        var meetingHistory: [DiagnosticsMeetingEntry]?
        if includeContent {
            questionAnswerHistory = (try? await questionAnswerRepository.history(limit: 1000))?.map {
                DiagnosticsQuestionAnswerEntry(
                    askedAt: $0.askedAt,
                    sourceAppBundleID: $0.sourceAppBundleID,
                    questionText: $0.questionText,
                    answerText: $0.answerText,
                    triggerKind: String(describing: $0.triggerKind)
                )
            } ?? []
            meetingHistory = (try? await meetingRepository.history(limit: 1000, offset: 0))?.map { meeting in
                DiagnosticsMeetingEntry(
                    startedAt: meeting.startedAt,
                    endedAt: meeting.endedAt,
                    sourceAppBundleID: meeting.sourceAppBundleID,
                    transcript: meeting.segments.map {
                        DiagnosticsTranscriptSegment(text: $0.text, startMs: $0.startMs, endMs: $0.endMs, source: String(describing: $0.source))
                    }
                )
            } ?? []
        }

        return DiagnosticsSnapshot(
            appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            currentMode: String(describing: mode),
            currentPhase: String(describing: phase),
            screenRecordingPermission: String(describing: screenRecording),
            microphonePermission: String(describing: microphone),
            metricCounts: counts,
            answerSession: answerSession(from: telemetry),
            includesConversationContent: includeContent,
            questionAnswerHistory: questionAnswerHistory,
            meetingHistory: meetingHistory
        )
    }

    static func answerSession(from telemetry: SessionTelemetrySnapshot) -> DiagnosticsAnswerSession {
        let configuration = telemetry.configuration
        let status: String = switch telemetry.status {
        case .providerError(let error): "provider_error:\(error.diagnosticCode)"
        default: String(describing: telemetry.status)
        }
        return DiagnosticsAnswerSession(
            provider: configuration?.selection.provider.rawValue,
            configuredModel: configuration?.selection.modelID,
            modelIsCustom: configuration?.selection.isCustom,
            servedModel: telemetry.servedModel,
            triggerMode: configuration?.triggerMode.rawValue,
            answerLength: configuration?.answerLength.rawValue,
            expertAreas: configuration?.expertAreas,
            status: status,
            usage: telemetry.usage,
            responsesWithUsage: telemetry.responsesWithUsage,
            responsesWithoutUsage: telemetry.responsesWithoutUsage,
            estimatedCostUSD: telemetry.cost?.approximateUSD,
            pricingSource: telemetry.cost?.pricing.sourceURL,
            pricingVerifiedOn: telemetry.cost?.pricing.verifiedOn,
            recognitionLatencyP50Ms: SessionTelemetrySnapshot.median(telemetry.recognitionLatencyMs),
            recognitionLatencyP95Ms: SessionTelemetrySnapshot.percentile95(telemetry.recognitionLatencyMs),
            questionToFirstTextP50Ms: SessionTelemetrySnapshot.median(telemetry.questionToFirstTextMs),
            questionToFirstTextP95Ms: SessionTelemetrySnapshot.percentile95(telemetry.questionToFirstTextMs),
            errorCounts: telemetry.errorCounts,
            lastErrorCode: telemetry.lastError?.diagnosticCode,
            reconnects: telemetry.reconnects,
            spendLimitUSD: telemetry.spendPolicy.limitUSD,
            spendState: String(describing: telemetry.spendState)
        )
    }

    static func encodeJSON(_ snapshot: DiagnosticsSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }
}
