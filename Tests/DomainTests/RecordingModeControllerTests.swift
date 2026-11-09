import Foundation
import Testing
@testable import Domain

@Suite struct RecordingModeControllerTests {

    @Test func stopFinalizesSegmentsAndMeetingThenReleasesResources() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let microphone = FakeMicrophoneCapturing()
        let transcribing = FakeLocalTranscribing()
        let repository = FakeMeetingRepository()
        await transcribing.setResult([TranscribedSegment(text: "привет", startMs: 0, endMs: 500, source: .local)])

        let controller = RecordingModeController(captureHub: CaptureHub(system: systemAudio, microphone: microphone), transcribing: transcribing, repository: repository, chunkDurationSeconds: 3600)
        try await controller.start()

        await microphone.emit(PCMAudioFrame(samples: [0], sampleRate: 24000, channelCount: 1, capturedAt: Date(), source: .microphone))
        try await Task.sleep(for: .milliseconds(20))

        #expect(await repository.appendedSegments.isEmpty)

        await controller.stop()

        let finished = await repository.finishedMeetings
        let appended = await repository.appendedSegments
        #expect(finished.count == 1)
        #expect(appended.count == 1)
        #expect(await microphone.stopCalled)
        #expect(await systemAudio.stopCalled)
    }

    @Test func stopYieldsFinishedMeetingIDForDownstreamExport() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let microphone = FakeMicrophoneCapturing()
        let transcribing = FakeLocalTranscribing()
        let repository = FakeMeetingRepository()

        let controller = RecordingModeController(captureHub: CaptureHub(system: systemAudio, microphone: microphone), transcribing: transcribing, repository: repository, chunkDurationSeconds: 3600)
        try await controller.start()
        await controller.stop()

        var receivedMeetingID: MeetingID?
        for await meetingID in controller.finishedMeetings() {
            receivedMeetingID = meetingID
            break
        }

        let created = await repository.createdMeetings
        #expect(receivedMeetingID == created.first)
    }

    @Test func doesNotCallRealtimeOrResponsesAPI() async throws {

        let systemAudio = FakeSystemAudioCapturing()
        let microphone = FakeMicrophoneCapturing()
        let transcribing = FakeLocalTranscribing()
        let repository = FakeMeetingRepository()
        let controller = RecordingModeController(captureHub: CaptureHub(system: systemAudio, microphone: microphone), transcribing: transcribing, repository: repository)

        try await controller.start()
        await controller.stop()

        let createdMeetings = await repository.createdMeetings
        let finishedMeetings = await repository.finishedMeetings
        #expect(createdMeetings.count == 1)
        #expect(finishedMeetings == createdMeetings)
    }

    @Test func transcriptionFailureIsReportedAsFailureNotCrash() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let microphone = FakeMicrophoneCapturing()
        let transcribing = FakeLocalTranscribing()
        await transcribing.setError(TestError(message: "model not loaded"))
        let repository = FakeMeetingRepository()

        let controller = RecordingModeController(captureHub: CaptureHub(system: systemAudio, microphone: microphone), transcribing: transcribing, repository: repository, chunkDurationSeconds: 0)
        try await controller.start()

        await microphone.emit(PCMAudioFrame(samples: [0], sampleRate: 24000, channelCount: 1, capturedAt: Date(), source: .microphone))

        var receivedFailure: String?
        for await reason in controller.failures() {
            receivedFailure = reason
            break
        }
        #expect(receivedFailure?.contains("model not loaded") == true)

        await controller.stop()
    }

    @Test func systemAndMicrophoneFramesAreTranscribedSeparatelyWithCorrectSource() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let microphone = FakeMicrophoneCapturing()
        let transcribing = SourceAwareFakeLocalTranscribing()
        let repository = FakeMeetingRepository()

        let controller = RecordingModeController(captureHub: CaptureHub(system: systemAudio, microphone: microphone), transcribing: transcribing, repository: repository, chunkDurationSeconds: 0)
        try await controller.start()

        await systemAudio.emit(PCMAudioFrame(samples: [0], sampleRate: 24000, channelCount: 1, capturedAt: Date(), source: .systemAudio))
        await microphone.emit(PCMAudioFrame(samples: [0], sampleRate: 24000, channelCount: 1, capturedAt: Date(), source: .microphone))
        try await Task.sleep(for: .milliseconds(30))

        await controller.stop()

        let appended = await repository.appendedSegments
        let remote = appended.first { $0.1.source == .remote }
        let local = appended.first { $0.1.source == .local }
        #expect(remote?.1.text == "system phrase")
        #expect(local?.1.text == "mic phrase")
        #expect(await transcribing.transcribeCallCount >= 2)
    }

    @Test func droppedFramesAreReportedToLatencyRecording() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let microphone = FakeMicrophoneCapturing()
        let transcribing = FakeLocalTranscribing()
        await transcribing.setDelay(.milliseconds(200))
        let repository = FakeMeetingRepository()
        let latency = FakeLatencyRecording()

        let controller = RecordingModeController(
            captureHub: CaptureHub(system: systemAudio, microphone: microphone), transcribing: transcribing, repository: repository,
            latencyRecording: latency, chunkDurationSeconds: 0, backpressureCapacity: 1
        )
        try await controller.start()

        for i in 0..<10 {
            await microphone.emit(PCMAudioFrame(samples: [Int16(i)], sampleRate: 24000, channelCount: 1, capturedAt: Date(), source: .microphone))
        }
        try await Task.sleep(for: .milliseconds(30))
        await controller.stop()

        let recorded = await latency.recordedMetrics
        #expect(recorded.contains { if case .droppedAudioFrames(let count) = $0 { count > 0 } else { false } })
    }

    @Test func audioIsWrittenToDiskOnlyWhenStorageIsEnabled() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let microphone = FakeMicrophoneCapturing()
        let transcribing = FakeLocalTranscribing()
        let repository = FakeMeetingRepository()
        let audioRecording = FakeMeetingAudioRecording()

        let controller = RecordingModeController(
            captureHub: CaptureHub(system: systemAudio, microphone: microphone), transcribing: transcribing, repository: repository,
            audioRecording: audioRecording, isAudioStorageEnabled: { true }, chunkDurationSeconds: 3600
        )
        try await controller.start()

        await microphone.emit(PCMAudioFrame(samples: [0], sampleRate: 16000, channelCount: 1, capturedAt: Date(), source: .microphone))
        try await Task.sleep(for: .milliseconds(20))

        await controller.stop()

        let createdMeetings = await repository.createdMeetings
        let startedMeetings = await audioRecording.startedMeetings
        #expect(startedMeetings == createdMeetings)
        #expect(await audioRecording.writtenFrames.count == 1)
        #expect(await audioRecording.finishCallCount == 1)
    }

    @Test func audioIsNotWrittenToDiskWhenStorageIsDisabled() async throws {
        let systemAudio = FakeSystemAudioCapturing()
        let microphone = FakeMicrophoneCapturing()
        let transcribing = FakeLocalTranscribing()
        let repository = FakeMeetingRepository()
        let audioRecording = FakeMeetingAudioRecording()

        let controller = RecordingModeController(
            captureHub: CaptureHub(system: systemAudio, microphone: microphone), transcribing: transcribing, repository: repository,
            audioRecording: audioRecording, isAudioStorageEnabled: { false }, chunkDurationSeconds: 3600
        )
        try await controller.start()

        await microphone.emit(PCMAudioFrame(samples: [0], sampleRate: 16000, channelCount: 1, capturedAt: Date(), source: .microphone))
        try await Task.sleep(for: .milliseconds(20))

        await controller.stop()

        #expect(await audioRecording.startedMeetings.isEmpty)
        #expect(await audioRecording.writtenFrames.isEmpty)
        #expect(await audioRecording.finishCallCount == 0)
    }
}
