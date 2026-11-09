import Diagnostics
import Domain
import Foundation
import RealtimeClient
import Testing

@Suite(.enabled(if: RealAPIEnvironment.isEnabled), .serialized)
struct RealAPISmokeTests {
    private func makeClient() -> OpenAIRealtimeAnswerClient {
        OpenAIRealtimeAnswerClient(credentialProviding: EnvironmentCredentialProvider(), latencyRecording: NoOpLatencyRecorder())
    }

    private func stream(_ samples: [Int16], into client: OpenAIRealtimeAnswerClient, trailingSilenceMs: Int = 1500) async {
        let frameSize = 480
        var index = 0
        while index < samples.count {
            let end = min(index + frameSize, samples.count)
            await client.appendAudio(PCMAudioFrame(samples: Array(samples[index..<end]), sampleRate: 24_000, channelCount: 1, capturedAt: Date(), source: .systemAudio))
            index = end
            try? await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<(trailingSilenceMs / 20) {
            await client.appendAudio(PCMAudioFrame(samples: Array(repeating: 0, count: frameSize), sampleRate: 24_000, channelCount: 1, capturedAt: Date(), source: .systemAudio))
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func firstDelta(from client: OpenAIRealtimeAnswerClient, timeout: Duration) async -> Duration? {
        let clock = ContinuousClock()
        let started = clock.now
        return await withTaskGroup(of: Duration?.self) { group in
            group.addTask {
                for await event in client.events() {
                    if case .textDelta = event { return clock.now - started }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test func audioToFirstTextDelta() async throws {
        let client = makeClient()
        try await client.start(instructions: RealtimeInstructions.system(for: .short))
        let samples = try SpeechFixture.pcm24k("What is the difference between a process and a thread?")
        async let delta = firstDelta(from: client, timeout: .seconds(20))
        await stream(samples, into: client)
        let elapsed = await delta
        await client.stop()
        #expect(elapsed != nil)
    }

    @Test func answerNowToFirstTextDelta() async throws {
        let client = makeClient()
        try await client.start(instructions: RealtimeInstructions.system(for: .short))
        let samples = try SpeechFixture.pcm24k("Let me describe our payment system. It has three services and a queue.")
        await stream(samples, into: client, trailingSilenceMs: 600)
        async let delta = firstDelta(from: client, timeout: .seconds(20))
        try await client.forceResponse()
        let elapsed = await delta
        await client.stop()
        #expect(elapsed != nil)
    }
}
