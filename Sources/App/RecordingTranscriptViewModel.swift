import Domain
import Observation

@MainActor
@Observable
final class RecordingTranscriptViewModel {
    private(set) var entries: [TranscribedSegment] = []

    init(recordingController: RecordingModeController) {
        Task { [weak self] in
            for await segment in recordingController.transcriptEvents() {
                self?.entries.append(segment)
            }
        }
    }

    func clear() {
        entries.removeAll()
    }

    func speakerLabel(for segment: TranscribedSegment) -> String {
        segment.source == .local ? loc("Я") : loc("Участники")
    }
}
