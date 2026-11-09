import Foundation
import os
import Testing
@testable import Domain

private final class ScriptedCatalog: AudioDeviceCataloging, Sendable {
    private struct State {
        var output: AudioDeviceInfo?
        var continuations: [UUID: AsyncStream<AudioDeviceChange>.Continuation] = [:]
        var added = 0
        var removed = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(output: AudioDeviceInfo?) {
        state = OSAllocatedUnfairLock(initialState: State(output: output))
    }

    func devices() -> [AudioDeviceInfo] { state.withLock { $0.output.map { [$0] } ?? [] } }
    func defaultInputUID() -> String? { nil }
    func defaultOutputDevice() -> AudioDeviceInfo? { state.withLock { $0.output } }

    func changes() -> AsyncStream<AudioDeviceChange> {
        let (stream, continuation) = AsyncStream<AudioDeviceChange>.makeStream()
        let id = UUID()
        state.withLock {
            $0.continuations[id] = continuation
            $0.added += 1
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock {
                $0.continuations[id] = nil
                $0.removed += 1
            }
        }
        return stream
    }

    func setOutput(_ device: AudioDeviceInfo?) {
        state.withLock { $0.output = device }
    }

    func emit(_ change: AudioDeviceChange) {
        let targets = state.withLock { Array($0.continuations.values) }
        for continuation in targets { continuation.yield(change) }
    }

    var counts: (added: Int, removed: Int) {
        state.withLock { ($0.added, $0.removed) }
    }
}

private let speakers = AudioDeviceInfo(id: 80, uid: "spk", name: "MacBook Pro Speakers", transport: .builtIn, hasInput: false, hasOutput: true, outputDataSource: AudioTransport.fourCC("ispk"))
private let airPods = AudioDeviceInfo(id: 90, uid: "pods", name: "AirPods", transport: .bluetooth, hasInput: true, hasOutput: true)

private actor RouteLog {
    private(set) var routes: [OutputRoute] = []
    func add(_ route: OutputRoute) { routes.append(route) }
}

@Suite struct OutputRouteMonitorTests {

    @Test func burstOfChangesDebouncedToOne() async throws {
        let catalog = ScriptedCatalog(output: speakers)
        let routes = AsyncBroadcaster<OutputRoute>()
        let notices = AsyncBroadcaster<CaptureNotice>()
        let noticeStream = notices.subscribe("test")
        let log = RouteLog()
        let stream = routes.subscribe("test")
        let collector = Task { for await route in stream { await log.add(route) } }
        let monitor = OutputRouteMonitor(catalog: catalog, routes: routes, notices: notices, debounce: .milliseconds(50))

        await monitor.start()
        catalog.setOutput(airPods)
        for _ in 0..<5 {
            catalog.emit(.defaultOutputChanged)
            catalog.emit(.outputDataSourceChanged)
        }
        try await Task.sleep(for: .milliseconds(250))

        #expect(await log.routes == [.builtInSpeakers, .bluetoothHeadphones(name: "AirPods")])
        #expect(await monitor.current == .bluetoothHeadphones(name: "AirPods"))
        var iterator = noticeStream.makeAsyncIterator()
        #expect(await iterator.next() == .outputRouteChanged(.bluetoothHeadphones(name: "AirPods")))
        await monitor.stop()
        routes.finish()
        await collector.value
    }

    @Test func unchangedRouteNotRepublished() async throws {
        let catalog = ScriptedCatalog(output: speakers)
        let routes = AsyncBroadcaster<OutputRoute>()
        let log = RouteLog()
        let stream = routes.subscribe("test")
        let collector = Task { for await route in stream { await log.add(route) } }
        let monitor = OutputRouteMonitor(catalog: catalog, routes: routes, debounce: .milliseconds(20))

        await monitor.start()
        catalog.emit(.defaultOutputChanged)
        try await Task.sleep(for: .milliseconds(100))
        catalog.emit(.deviceListChanged)
        try await Task.sleep(for: .milliseconds(100))

        #expect(await log.routes == [.builtInSpeakers])
        await monitor.stop()
        routes.finish()
        await collector.value
    }

    @Test func stopRemovesListeners() async throws {
        let catalog = ScriptedCatalog(output: speakers)
        let monitor = OutputRouteMonitor(catalog: catalog, routes: AsyncBroadcaster<OutputRoute>(), debounce: .milliseconds(20))

        await monitor.start()
        await monitor.start()
        #expect(catalog.counts.added == 1)
        await monitor.stop()
        try await Task.sleep(for: .milliseconds(50))

        #expect(catalog.counts.removed == 1)
        #expect(await monitor.isRunning == false)
        catalog.setOutput(airPods)
        catalog.emit(.defaultOutputChanged)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await monitor.current == .builtInSpeakers)
    }
}
