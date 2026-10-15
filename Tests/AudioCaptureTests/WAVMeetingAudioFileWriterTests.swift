import AVFAudio
import Domain
import Foundation
import Testing
@testable import AudioCapture

@Suite struct WAVMeetingAudioFileWriterTests {

    @Test func writesSeparateWAVFilesPerSourceWithAllSamples() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let writer = WAVMeetingAudioFileWriter(baseDirectory: baseDirectory)
        let meetingID = MeetingID()
        await writer.start(meetingID: meetingID)

        let micSamplesA: [Int16] = [1, 2, 3, 4]
        let micSamplesB: [Int16] = [5, 6]
        let systemSamples: [Int16] = [10, 20, 30]

        await writer.write(PCMAudioFrame(samples: micSamplesA, sampleRate: 16000, channelCount: 1, capturedAt: Date(), source: .microphone))
        await writer.write(PCMAudioFrame(samples: micSamplesB, sampleRate: 16000, channelCount: 1, capturedAt: Date(), source: .microphone))
        await writer.write(PCMAudioFrame(samples: systemSamples, sampleRate: 16000, channelCount: 1, capturedAt: Date(), source: .systemAudio))
        await writer.finish()

        let meetingDirectory = baseDirectory.appendingPathComponent(meetingID.rawValue.uuidString, isDirectory: true)
        let micURL = meetingDirectory.appendingPathComponent("mic.wav")
        let systemURL = meetingDirectory.appendingPathComponent("system.wav")

        #expect(FileManager.default.fileExists(atPath: micURL.path))
        #expect(FileManager.default.fileExists(atPath: systemURL.path))

        let micFile = try AVAudioFileTestReader(url: micURL)
        #expect(micFile.frameCount == micSamplesA.count + micSamplesB.count)

        let systemFile = try AVAudioFileTestReader(url: systemURL)
        #expect(systemFile.frameCount == systemSamples.count)
    }

    @Test func emptyFrameIsIgnored() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let writer = WAVMeetingAudioFileWriter(baseDirectory: baseDirectory)
        let meetingID = MeetingID()
        await writer.start(meetingID: meetingID)
        await writer.write(PCMAudioFrame(samples: [], sampleRate: 16000, channelCount: 1, capturedAt: Date(), source: .microphone))
        await writer.finish()

        let micURL = baseDirectory.appendingPathComponent(meetingID.rawValue.uuidString, isDirectory: true).appendingPathComponent("mic.wav")
        #expect(!FileManager.default.fileExists(atPath: micURL.path))
    }
}

private struct AVAudioFileTestReader {
    let frameCount: Int

    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        frameCount = Int(file.length)
    }
}
