import Domain
import Foundation

public enum TranscriptFormatter {
    public static func renderMarkdown(
        _ segments: [TranscribedSegment],
        localSpeakerLabel: String = "Я",
        remoteSpeakerLabel: String = "Участники"
    ) -> String {
        segments.map { segment in
            "[\(formatTimestamp(segment.startMs))–\(formatTimestamp(segment.endMs))] \(speakerLabel(segment, localSpeakerLabel: localSpeakerLabel, remoteSpeakerLabel: remoteSpeakerLabel)): \(segment.text)"
        }.joined(separator: "\n")
    }

    public static func renderJSON(
        _ segments: [TranscribedSegment],
        localSpeakerLabel: String = "Я",
        remoteSpeakerLabel: String = "Участники"
    ) throws -> Data {
        let rows = segments.map { segment in
            TranscriptRow(
                speaker: speakerLabel(segment, localSpeakerLabel: localSpeakerLabel, remoteSpeakerLabel: remoteSpeakerLabel),
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rows)
    }

    private static func speakerLabel(_ segment: TranscribedSegment, localSpeakerLabel: String, remoteSpeakerLabel: String) -> String {
        segment.source == .local ? localSpeakerLabel : remoteSpeakerLabel
    }

    private static func formatTimestamp(_ ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private struct TranscriptRow: Codable {
        let speaker: String
        let startMs: Int
        let endMs: Int
        let text: String
    }
}
