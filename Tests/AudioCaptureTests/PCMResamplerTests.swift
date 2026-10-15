import Foundation
import Testing
@testable import AudioCapture
@testable import Domain

@Suite struct PCMResamplerTests {

    @Test func downmixAveragesChannels() {

        let stereo: [Int16] = [100, 200, 0, 0]
        let mono = PCMResampler.downmixToMono(samples: stereo, channelCount: 2)
        #expect(mono == [150, 0])
    }

    @Test func downmixIsNoOpForMono() {
        let samples: [Int16] = [1, 2, 3]
        #expect(PCMResampler.downmixToMono(samples: samples, channelCount: 1) == samples)
    }

    @Test func resampleDownProducesExpectedLength() {

        let input = [Int16](repeating: 1000, count: 480)
        let output = PCMResampler.resample(monoSamples: input, fromRate: 48_000, toRate: 24_000)
        #expect(output.count == 240)
    }

    @Test func resampleUpProducesExpectedLength() {

        let input = [Int16](repeating: 1000, count: 320)
        let output = PCMResampler.resample(monoSamples: input, fromRate: 16_000, toRate: 24_000)
        #expect(output.count == 480)
    }

    @Test func resampleConstantSignalStaysConstant() {
        let input = [Int16](repeating: 12345, count: 100)
        let output = PCMResampler.resample(monoSamples: input, fromRate: 44_100, toRate: 16_000)
        #expect(output.allSatisfy { $0 == 12345 })
    }

    @Test func resampleNoOpWhenRatesMatch() {
        let input: [Int16] = [1, 2, 3, 4]
        #expect(PCMResampler.resample(monoSamples: input, fromRate: 24_000, toRate: 24_000) == input)
    }

    @Test func realtimeConverterProducesUniform20msFrames() {
        var converter = RealtimeAudioFormatConverter()
        let now = Date()

        let input = PCMAudioFrame(samples: [Int16](repeating: 500, count: 4800), sampleRate: 48_000, channelCount: 1, capturedAt: now, source: .systemAudio)

        let outputs = converter.convert(input)

        #expect(outputs.count == 5)
        for frame in outputs {
            #expect(frame.samples.count == RealtimeAudioFormatConverter.samplesPerFrame)
            #expect(frame.sampleRate == 24_000)
            #expect(frame.channelCount == 1)
            #expect(frame.source == .systemAudio)
        }
    }

    @Test func realtimeConverterCarriesPartialTailAcrossCalls() {
        var converter = RealtimeAudioFormatConverter()
        let now = Date()

        let first = PCMAudioFrame(samples: [Int16](repeating: 1, count: 600), sampleRate: 24_000, channelCount: 1, capturedAt: now, source: .systemAudio)
        let firstOutputs = converter.convert(first)
        #expect(firstOutputs.count == 1)

        let second = PCMAudioFrame(samples: [Int16](repeating: 2, count: 360), sampleRate: 24_000, channelCount: 1, capturedAt: now, source: .systemAudio)
        let secondOutputs = converter.convert(second)
        #expect(secondOutputs.count == 1)
        #expect(secondOutputs[0].samples.count == RealtimeAudioFormatConverter.samplesPerFrame)
    }

    @Test func whisperConverterTargets16kHzMono() {
        let now = Date()
        let input = PCMAudioFrame(samples: [Int16](repeating: 999, count: 4800), sampleRate: 48_000, channelCount: 2, capturedAt: now, source: .microphone)
        let output = WhisperAudioFormatConverter.convert(input)
        #expect(output.sampleRate == 16_000)
        #expect(output.channelCount == 1)
        #expect(output.source == .microphone)
    }

    @Test func timestampsPreserveMonotonicOrderThroughConversion() {
        var converter = RealtimeAudioFormatConverter()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(0.02)
        let f0 = PCMAudioFrame(samples: [Int16](repeating: 0, count: 480), sampleRate: 24_000, channelCount: 1, capturedAt: t0, source: .systemAudio)
        let f1 = PCMAudioFrame(samples: [Int16](repeating: 0, count: 480), sampleRate: 24_000, channelCount: 1, capturedAt: t1, source: .systemAudio)

        let out0 = converter.convert(f0)
        let out1 = converter.convert(f1)

        #expect(out0.first!.capturedAt <= out1.first!.capturedAt)
    }
}
