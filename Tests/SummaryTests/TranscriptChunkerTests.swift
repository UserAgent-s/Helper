import Domain
import Testing
@testable import Summary

@Suite struct TranscriptChunkerTests {

    private func segments(count: Int, textLength: Int = 30) -> [TranscribedSegment] {
        (0..<count).map { i in
            TranscribedSegment(text: String(repeating: "x", count: textLength), startMs: i * 1000, endMs: i * 1000 + 900, source: .remote)
        }
    }

    @Test func returnsSingleChunkWhenUnderLimit() {
        let chunks = TranscriptChunker.chunk(segments(count: 5), maxCharactersPerChunk: 10_000)
        #expect(chunks.count == 1)
        #expect(chunks.first?.count == 5)
    }

    @Test func splitsIntoMultipleChunksWhenOverLimit() {
        let chunks = TranscriptChunker.chunk(segments(count: 100, textLength: 50), maxCharactersPerChunk: 500)
        #expect(chunks.count > 1)
    }

    @Test func neverSplitsASegmentAcrossChunks() {
        let all = segments(count: 40, textLength: 20)
        let chunks = TranscriptChunker.chunk(all, maxCharactersPerChunk: 300)
        let flattened = chunks.flatMap { $0 }
        #expect(flattened.count == all.count)
        #expect(flattened.map(\.startMs) == all.map(\.startMs))
    }

    @Test func emptyTranscriptProducesNoChunks() {
        let chunks = TranscriptChunker.chunk([], maxCharactersPerChunk: 1000)
        #expect(chunks.isEmpty)
    }
}
