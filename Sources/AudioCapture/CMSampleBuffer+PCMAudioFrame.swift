import AVFAudio
import CoreAudio
import CoreMedia
import Foundation
import Domain

enum PCMAudioFrameExtraction {
    static func makeFrame(from sampleBuffer: CMSampleBuffer, source: AudioSourceKind) -> PCMAudioFrame? {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }
        let asbd = asbdPointer.pointee

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        let channelCount = Int(asbd.mChannelsPerFrame)
        guard channelCount > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        let bufferListSize = AudioBufferList.sizeInBytes(maximumBuffers: channelCount)
        let listPointer = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { listPointer.unsafeMutablePointer.deallocate() }

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer.unsafeMutablePointer,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        var interleavedInt16 = [Int16](repeating: 0, count: numSamples * channelCount)

        if channelCount == 1 || (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 {

            for (channelIndex, audioBuffer) in listPointer.enumerated() where channelIndex < channelCount {
                guard let data = audioBuffer.mData else { continue }
                let frameCount = min(numSamples, Int(audioBuffer.mDataByteSize) / (isFloat ? 4 : 2))
                if isFloat {
                    let floatPointer = data.assumingMemoryBound(to: Float32.self)
                    for i in 0..<frameCount {
                        interleavedInt16[i * channelCount + channelIndex] = Self.floatToInt16(floatPointer[i])
                    }
                } else {
                    let int16Pointer = data.assumingMemoryBound(to: Int16.self)
                    for i in 0..<frameCount {
                        interleavedInt16[i * channelCount + channelIndex] = int16Pointer[i]
                    }
                }
            }
        } else if let audioBuffer = listPointer.first, let data = audioBuffer.mData {

            let totalSamples = min(numSamples * channelCount, Int(audioBuffer.mDataByteSize) / (isFloat ? 4 : 2))
            if isFloat {
                let floatPointer = data.assumingMemoryBound(to: Float32.self)
                for i in 0..<totalSamples {
                    interleavedInt16[i] = Self.floatToInt16(floatPointer[i])
                }
            } else {
                let int16Pointer = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<totalSamples {
                    interleavedInt16[i] = int16Pointer[i]
                }
            }
        } else {
            return nil
        }

        return PCMAudioFrame(
            samples: interleavedInt16,
            sampleRate: Int(asbd.mSampleRate),
            channelCount: channelCount,
            capturedAt: Date(),
            source: source
        )
    }

    private static func floatToInt16(_ sample: Float32) -> Int16 {
        let clamped = max(-1.0, min(1.0, sample))
        return Int16(clamping: Int(clamped * Float32(Int16.max)))
    }
}
