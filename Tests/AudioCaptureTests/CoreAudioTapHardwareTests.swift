import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import AudioCapture
@testable import Domain

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["USERAGENT057_HARDWARE"] == "1"))
struct CoreAudioTapHardwareTests {

    @Test func tapDeliversNonSilentFramesWhileSystemSoundPlays() async throws {
        guard #available(macOS 14.2, *) else { return }
        let capturing = CoreAudioTapSystemAudioCapturing(catalog: CoreAudioDeviceCatalog())
        let start = try await capturing.start(scope: .defaultScope)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["/System/Library/Sounds/Glass.aiff"]
        try player.run()

        let collector = Task { () -> (frames: Int, peak: Int) in
            var frames = 0
            var peak = 0
            for await frame in start.frames {
                frames += 1
                peak = max(peak, frame.samples.map { abs(Int($0)) }.max() ?? 0)
            }
            return (frames, peak)
        }
        try await Task.sleep(for: .seconds(3))
        await capturing.stop()
        let result = await collector.value
        print("TAP_SMOKE frames=\(result.frames) peak=\(result.peak) expectedFrames=150")
        #expect(result.frames > 100)
        #expect(result.peak > 0)
    }

    @Test func ownProcessAudioIsExcludedAndStartIsTimed() async throws {
        guard #available(macOS 14.2, *) else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 3)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) / 48_000 * 2 * .pi * 880) * 0.5)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
        defer {
            player.stop()
            engine.stop()
        }
        let own = try #require(TapDescriptionBuilder.ownProcessObjectID())

        let onlyOwn = try await Self.measure { capturing in
            try await capturing.startTap(CATapDescription(stereoMixdownOfProcesses: [own]), effectiveScope: .defaultScope, notice: nil)
        }
        let excludingOwn = try await Self.measure { capturing in
            try await capturing.start(scope: .defaultScope)
        }
        print("TAP_SELF onlyOwn ratio=\(onlyOwn.ratio) peak=\(onlyOwn.peak) | excludingOwn ratio=\(excludingOwn.ratio) peak=\(excludingOwn.peak) startCall=\(excludingOwn.startCall) firstFrame=\(String(describing: excludingOwn.firstFrame))")
        #expect(onlyOwn.ratio > 0.5)
        #expect(excludingOwn.ratio < 0.05)
    }

    @available(macOS 14.2, *)
    private static func measure(_ begin: (CoreAudioTapSystemAudioCapturing) async throws -> SystemAudioCaptureStart) async throws -> (ratio: Double, peak: Int, startCall: Duration, firstFrame: Duration?) {
        let capturing = CoreAudioTapSystemAudioCapturing(catalog: CoreAudioDeviceCatalog())
        let clock = ContinuousClock()
        let begun = clock.now
        let start = try await begin(capturing)
        let startCall = clock.now - begun
        let collector = Task { () -> (samples: [Int16], firstFrame: Duration?) in
            var samples: [Int16] = []
            var first: Duration?
            for await frame in start.frames {
                if first == nil { first = clock.now - begun }
                samples.append(contentsOf: frame.samples)
            }
            return (samples, first)
        }
        try await Task.sleep(for: .milliseconds(1500))
        await capturing.stop()
        let result = await collector.value
        return (toneEnergyRatio(result.samples, sampleRate: 24_000, frequency: 880), result.samples.map { abs(Int($0)) }.max() ?? 0, startCall, result.firstFrame)
    }

    private static func toneEnergyRatio(_ samples: [Int16], sampleRate: Double, frequency: Double) -> Double {
        guard samples.count > 0 else { return 0 }
        let coefficient = 2 * cos(2 * .pi * frequency / sampleRate)
        var s1 = 0.0
        var s2 = 0.0
        var total = 0.0
        for sample in samples {
            let x = Double(sample)
            total += x * x
            let s0 = x + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
        guard total > 0 else { return 0 }
        return min(1, 2 * power / (Double(samples.count) * total))
    }

    @Test func baselineWithoutOwnTone() async throws {
        guard #available(macOS 14.2, *) else { return }
        let own = TapDescriptionBuilder.ownProcessObjectID()
        let processes = TapDescriptionBuilder.audioProcesses()
        print("TAP_DEBUG pid=\(getpid()) own=\(String(describing: own)) listed=\(processes.contains { $0.objectID == own }) count=\(processes.count) bundles=\(processes.compactMap(\.bundleID).prefix(40))")
        let capturing = CoreAudioTapSystemAudioCapturing(catalog: CoreAudioDeviceCatalog())
        let start = try await capturing.start(scope: .defaultScope)
        let collector = Task { () -> Int in
            var peak = 0
            for await frame in start.frames { peak = max(peak, frame.samples.map { abs(Int($0)) }.max() ?? 0) }
            return peak
        }
        try await Task.sleep(for: .seconds(2))
        await capturing.stop()
        print("TAP_BASELINE peak=\(await collector.value)")
    }

    @Test func screenCaptureKitComparison() async throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 3)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) / 48_000 * 2 * .pi * 880) * 0.5)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
        defer {
            player.stop()
            engine.stop()
        }
        let capturing = ScreenCaptureKitSystemAudioCapturing(outputFormat: .realtimeStreaming)
        let clock = ContinuousClock()
        let begun = clock.now
        let start: SystemAudioCaptureStart
        do {
            start = try await capturing.start(scope: .defaultScope)
        } catch {
            print("SCK_COMPARE unavailable error=\(error)")
            return
        }
        let startCall = clock.now - begun
        let collector = Task { () -> (samples: [Int16], frames: Int, firstFrame: Duration?) in
            var samples: [Int16] = []
            var frames = 0
            var first: Duration?
            for await frame in start.frames {
                if first == nil { first = clock.now - begun }
                frames += 1
                samples.append(contentsOf: frame.samples)
            }
            return (samples, frames, first)
        }
        try await Task.sleep(for: .milliseconds(1500))
        await capturing.stop()
        let result = await collector.value
        print("SCK_COMPARE frames=\(result.frames) ratio=\(Self.toneEnergyRatio(result.samples, sampleRate: 24_000, frequency: 880)) startCall=\(startCall) firstFrame=\(String(describing: result.firstFrame))")
    }

    @Test func tapCPUCostOverTenSeconds() async throws {
        guard #available(macOS 14.2, *) else { return }
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let capturing = CoreAudioTapSystemAudioCapturing(catalog: CoreAudioDeviceCatalog())
        let start = try await capturing.start(scope: .defaultScope)
        let collector = Task { () -> Int in
            var frames = 0
            for await _ in start.frames { frames += 1 }
            return frames
        }
        let before = cpuSeconds()
        try await Task.sleep(for: .seconds(10))
        let used = cpuSeconds() - before
        await capturing.stop()
        let frames = await collector.value
        print("TAP_CPU seconds=\(used) percentOfOneCore=\(used / 10 * 100) frames=\(frames)")
    }
}
