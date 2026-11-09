import Domain
import Foundation
import Summary

final class MeetingFolderExporter: @unchecked Sendable {
    private let meetingRepository: any MeetingRepository
    private let baseDirectory: URL
    private let fileManager: FileManager

    init(meetingRepository: any MeetingRepository, baseDirectory: URL, fileManager: FileManager = .default) {
        self.meetingRepository = meetingRepository
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    func export(meetingID: MeetingID, audioSourceDirectory: URL? = nil) async {
        guard let meeting = try? await meetingRepository.fetch(meetingID: meetingID) else { return }

        let folder = baseDirectory.appendingPathComponent(Self.folderName(for: meeting.startedAt), isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let localSpeakerLabel = await loc("Я")
        let remoteSpeakerLabel = await loc("Участники")
        let markdown = TranscriptFormatter.renderMarkdown(
            meeting.segments,
            localSpeakerLabel: localSpeakerLabel,
            remoteSpeakerLabel: remoteSpeakerLabel
        )
        try? markdown.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)

        guard let audioSourceDirectory, fileManager.fileExists(atPath: audioSourceDirectory.path) else { return }
        let names = (try? fileManager.contentsOfDirectory(atPath: audioSourceDirectory.path)) ?? []
        for fileName in names.filter({ $0.hasSuffix(".wav") }).sorted() {
            let source = audioSourceDirectory.appendingPathComponent(fileName)
            let destination = folder.appendingPathComponent(fileName)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.copyItem(at: source, to: destination)
        }
    }

    static func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return "\(formatter.string(from: date)) UserAgent057"
    }
}
