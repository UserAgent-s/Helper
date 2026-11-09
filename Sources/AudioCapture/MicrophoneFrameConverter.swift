import Domain
import Foundation

public enum MicrophoneFrameConverter {
    public static func monoSamples(interleaved: [Int16], channelCount: Int, voiceProcessing: Bool) -> [Int16] {
        guard channelCount > 1 else { return interleaved }
        guard voiceProcessing else {
            return PCMResampler.downmixToMono(samples: interleaved, channelCount: channelCount)
        }
        let frameCount = interleaved.count / channelCount
        var mono = [Int16](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            mono[index] = interleaved[index * channelCount]
        }
        return mono
    }

    public static func convert(_ frame: PCMAudioFrame, options: MicrophoneCaptureOptions) -> PCMAudioFrame {
        let mono = monoSamples(interleaved: frame.samples, channelCount: frame.channelCount, voiceProcessing: options.voiceProcessing)
        return PCMAudioFrame(
            samples: PCMResampler.resample(monoSamples: mono, fromRate: frame.sampleRate, toRate: options.sampleRate),
            sampleRate: options.sampleRate,
            channelCount: 1,
            capturedAt: frame.capturedAt,
            source: .microphone
        )
    }
}
