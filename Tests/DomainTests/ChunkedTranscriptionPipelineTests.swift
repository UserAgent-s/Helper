import Foundation
import Testing
@testable import Domain

@Suite struct ChunkedTranscriptionPipelineTests {

    private func frame(sampleCount: Int, sampleRate: Int = 1000, source: AudioSourceKind = .microphone) -> PCMAudioFrame {
        PCMAudioFrame(samples: Array(repeating: 0, count: sampleCount), sampleRate: sampleRate, channelCount: 1, capturedAt: Date(), source: source)
    }

    @Test func ingestReportsFlushOnlyAfterChunkDurationReached() async {
        let transcribing = FakeLocalTranscribing()
        let pipeline = ChunkedTranscriptionPipeline(transcribing: transcribing, chunkDurationSeconds: 1, overlapSeconds: 0.2)

        var shouldFlushFlags: [Bool] = []
        for _ in 0..<10 {
            shouldFlushFlags.append(await pipeline.ingest(frame(sampleCount: 100)))
        }

        #expect(shouldFlushFlags.dropLast().allSatisfy { $0 == false })
        #expect(shouldFlushFlags.last == true)
    }

    @Test func sourceIsPreservedThroughFlush() async throws {
        let transcribing = FakeLocalTranscribing()
        await transcribing.setResult([TranscribedSegment(text: "hello", startMs: 0, endMs: 500, source: .remote)])
        let pipeline = ChunkedTranscriptionPipeline(transcribing: transcribing, chunkDurationSeconds: 1, overlapSeconds: 0.2)

        for _ in 0..<10 { _ = await pipeline.ingest(frame(sampleCount: 100)) }
        let segments = try await pipeline.flush()

        #expect(segments.first?.source == .remote)
    }

    @Test func firstFlushKeepsAllSegmentsWithoutOverlapFiltering() async throws {
        let transcribing = FakeLocalTranscribing()
        await transcribing.setResult([
            TranscribedSegment(text: "early", startMs: 0, endMs: 100, source: .local),
            TranscribedSegment(text: "late", startMs: 900, endMs: 1000, source: .local),
        ])
        let pipeline = ChunkedTranscriptionPipeline(transcribing: transcribing, chunkDurationSeconds: 1, overlapSeconds: 0.2)

        for _ in 0..<10 { _ = await pipeline.ingest(frame(sampleCount: 100)) }
        let segments = try await pipeline.flush()

        #expect(segments.map(\.text) == ["early", "late"])
    }

    @Test func secondFlushDropsSegmentsInsideOverlapWindow() async throws {
        let transcribing = FakeLocalTranscribing()
        let pipeline = ChunkedTranscriptionPipeline(transcribing: transcribing, chunkDurationSeconds: 1, overlapSeconds: 0.2)

        for _ in 0..<10 { _ = await pipeline.ingest(frame(sampleCount: 100)) }
        await transcribing.setResult([TranscribedSegment(text: "carried over", startMs: 0, endMs: 200, source: .local)])
        _ = try await pipeline.flush()

        await transcribing.setResult([
            TranscribedSegment(text: "carried over", startMs: 0, endMs: 200, source: .local),
            TranscribedSegment(text: "new material", startMs: 400, endMs: 900, source: .local),
        ])
        for _ in 0..<10 { _ = await pipeline.ingest(frame(sampleCount: 100)) }
        let secondSegments = try await pipeline.flush()

        #expect(secondSegments.map(\.text) == ["new material"])
    }

    @Test func absoluteTimestampsAccumulateAcrossFlushes() async throws {
        let transcribing = FakeLocalTranscribing()
        let pipeline = ChunkedTranscriptionPipeline(transcribing: transcribing, chunkDurationSeconds: 1, overlapSeconds: 0.2)

        for _ in 0..<10 { _ = await pipeline.ingest(frame(sampleCount: 100)) }
        await transcribing.setResult([TranscribedSegment(text: "first chunk", startMs: 300, endMs: 400, source: .local)])
        let firstSegments = try await pipeline.flush()
        #expect(firstSegments.first?.startMs == 300)

        for _ in 0..<10 { _ = await pipeline.ingest(frame(sampleCount: 100)) }
        await transcribing.setResult([TranscribedSegment(text: "second chunk", startMs: 300, endMs: 400, source: .local)])
        let secondSegments = try await pipeline.flush()

        #expect(secondSegments.first?.startMs == 300 + 800)
    }

    @Test func tailAudioCarriedForwardMatchesOverlapDuration() async throws {
        let transcribing = FakeLocalTranscribing()
        let pipeline = ChunkedTranscriptionPipeline(transcribing: transcribing, chunkDurationSeconds: 1, overlapSeconds: 0.2)

        for _ in 0..<10 { _ = await pipeline.ingest(frame(sampleCount: 100)) }
        _ = try await pipeline.flush()

        _ = await pipeline.ingest(frame(sampleCount: 100))
        _ = try await pipeline.flush()

        let secondBatch = await transcribing.receivedFrameBatches[1]
        let totalSamples = secondBatch.reduce(0) { $0 + $1.samples.count }
        #expect(totalSamples == 300)
    }

    @Test func pipelinePreservesLanguageAndConfidence() async throws {
        let transcribing = FakeLocalTranscribing()
        await transcribing.setResult([TranscribedSegment(text: "привет", startMs: 0, endMs: 500, source: .remote, language: "ru", confidence: 0.8)])
        let pipeline = ChunkedTranscriptionPipeline(transcribing: transcribing, chunkDurationSeconds: 1, overlapSeconds: 0.2)

        for _ in 0..<10 { _ = await pipeline.ingest(frame(sampleCount: 100)) }
        let segments = try await pipeline.flush()

        #expect(segments.first?.language == "ru")
        #expect(segments.first?.confidence == 0.8)
    }
}
