import Domain

public enum TranscriptChunker {
    public static func chunk(_ segments: [TranscribedSegment], maxCharactersPerChunk: Int) -> [[TranscribedSegment]] {
        guard !segments.isEmpty else { return [] }

        var chunks: [[TranscribedSegment]] = []
        var current: [TranscribedSegment] = []
        var currentLength = 0

        for segment in segments {
            let segmentLength = segment.text.count + 32
            if !current.isEmpty, currentLength + segmentLength > maxCharactersPerChunk {
                chunks.append(current)
                current = []
                currentLength = 0
            }
            current.append(segment)
            currentLength += segmentLength
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
