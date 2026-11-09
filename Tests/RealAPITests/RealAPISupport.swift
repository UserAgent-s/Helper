import AVFoundation
import Domain
import Foundation
import RealtimeClient
import Testing

struct EnvironmentCredentialProvider: RealtimeCredentialProviding {
    func currentCredential() async throws -> RealtimeCredential {
        RealtimeCredential(apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "")
    }
}

enum SpeechFixture {
    static func pcm24k(_ text: String, voice: String? = nil) throws -> [Int16] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ua057-\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = (voice.map { ["-v", $0] } ?? []) + ["-o", url.path, "--file-format=WAVE", "--data-format=LEI16@24000", text]
        try process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.int16ChannelData)
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    static func silence(ms: Int) -> [Int16] {
        Array(repeating: 0, count: 24 * ms)
    }

    static func attenuated(_ samples: [Int16], decibels: Double, delayMs: Int) -> [Int16] {
        let gain = pow(10, decibels / 20)
        return silence(ms: delayMs) + samples.map { Int16(clamping: Int(Double($0) * gain)) }
    }
}

enum RealAPIEnvironment {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["RUN_REAL_API_TESTS"] == "1" }

    static func rounds(default value: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment["ME_LATENCY_ROUNDS"], let parsed = Int(raw), parsed > 0 else { return value }
        return min(parsed, 10)
    }
}

struct LatencySummary: CustomStringConvertible {
    let label: String
    let valuesMs: [Int]

    var sorted: [Int] { valuesMs.sorted() }
    var p50: Int { percentile(0.5) }
    var p95: Int { percentile(0.95) }

    func percentile(_ fraction: Double) -> Int {
        let values = sorted
        guard !values.isEmpty else { return 0 }
        let rank = Int((Double(values.count) * fraction).rounded(.up)) - 1
        return values[min(values.count - 1, max(0, rank))]
    }

    var description: String {
        "VERIFY_REAL \(label) n=\(valuesMs.count) p50=\(p50)ms p95=\(p95)ms max=\(sorted.last ?? 0)ms values=\(sorted)"
    }
}

extension Duration {
    var milliseconds: Int {
        let parts = components
        return Int(parts.seconds * 1_000) + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

actor PacedFrameEmitter {
    private let clock = ContinuousClock()
    private var next: ContinuousClock.Instant?

    func emit(_ samples: [Int16], source: AudioSourceKind, sink: @Sendable (PCMAudioFrame) async -> Void) async {
        var index = 0
        while index < samples.count {
            let end = min(index + 480, samples.count)
            let deadline = (next ?? clock.now).advanced(by: .milliseconds(20))
            await sink(PCMAudioFrame(samples: Array(samples[index..<end]), sampleRate: 24_000, channelCount: 1, capturedAt: Date(), source: source))
            next = deadline
            try? await clock.sleep(until: deadline)
            index = end
        }
    }
}
