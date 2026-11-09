import AVFAudio
import Domain
import Foundation

public actor WAVMeetingAudioFileWriter: MeetingAudioRecording {
    private let baseDirectory: URL
    private var meetingDirectory: URL?
    private var systemFile: AVAudioFile?
    private var microphoneFile: AVAudioFile?

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public func start(meetingID: MeetingID) async {
        let directory = baseDirectory.appendingPathComponent(meetingID.rawValue.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        meetingDirectory = directory
        systemFile = nil
        microphoneFile = nil
    }

    public func write(_ frame: PCMAudioFrame) async {
        guard let meetingDirectory, !frame.samples.isEmpty else { return }
        guard let file = try? file(for: frame.source, in: meetingDirectory, sampleRate: frame.sampleRate, channelCount: frame.channelCount) else { return }
        guard let buffer = Self.makeBuffer(from: frame, format: file.processingFormat) else { return }
        try? file.write(from: buffer)
    }

    public func finish() async {
        systemFile = nil
        microphoneFile = nil
        meetingDirectory = nil
    }

    private func file(for source: AudioSourceKind, in directory: URL, sampleRate: Int, channelCount: Int) throws -> AVAudioFile {
        switch source {
        case .microphone:
            if let microphoneFile { return microphoneFile }
            let file = try Self.makeFile(at: Self.freshURL(in: directory, stem: "mic"), sampleRate: sampleRate, channelCount: channelCount)
            microphoneFile = file
            return file
        case .systemAudio:
            if let systemFile { return systemFile }
            let file = try Self.makeFile(at: Self.freshURL(in: directory, stem: "system"), sampleRate: sampleRate, channelCount: channelCount)
            systemFile = file
            return file
        }
    }

    static func freshURL(in directory: URL, stem: String) -> URL {
        let first = directory.appendingPathComponent("\(stem).wav")
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        var index = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(stem)-\(index).wav").path) {
            index += 1
        }
        return directory.appendingPathComponent("\(stem)-\(index).wav")
    }

    private static func makeFile(at url: URL, sampleRate: Int, channelCount: Int) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
    }

    private static func makeBuffer(from frame: PCMAudioFrame, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard frame.channelCount > 0 else { return nil }
        let frameCount = AVAudioFrameCount(frame.samples.count / frame.channelCount)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let channelData = buffer.int16ChannelData else { return nil }
        frame.samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channelData[0].update(from: baseAddress, count: frame.samples.count)
        }
        return buffer
    }
}
