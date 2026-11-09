import Testing
@testable import Domain

@Suite struct ModeCoordinatorTests {

    private func makeCoordinator(
        recorder: CallRecorder,
        answersError: TestError? = nil,
        recordingError: TestError? = nil,
        answersStartDelay: Duration = .zero,
        recordingStartDelay: Duration = .zero
    ) -> ModeCoordinator {
        let answers = FakeModeController(label: "answers", recorder: recorder, startError: answersError, startDelay: answersStartDelay)
        let recording = FakeModeController(label: "recording", recorder: recorder, startError: recordingError, startDelay: recordingStartDelay)
        return ModeCoordinator(controllers: [.answers: answers, .recording: recording])
    }

    @Test func startsInPassive() async {
        let coordinator = makeCoordinator(recorder: CallRecorder())
        #expect(await coordinator.currentMode == .passive)
    }

    @Test func stoppingActiveModeRecordsModeStopLatency() async {
        let recorder = CallRecorder()
        let latency = FakeLatencyRecording()
        let answers = FakeModeController(label: "answers", recorder: recorder)
        let coordinator = ModeCoordinator(controllers: [.answers: answers], latencyRecording: latency)

        _ = await coordinator.requestTransition(to: .answers)
        _ = await coordinator.requestTransition(to: .passive)

        let recorded = await latency.recordedMetrics
        #expect(recorded.contains { if case .modeStopMs = $0 { true } else { false } })
    }

    @Test func sixDirectedTransitions() async {
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        #expect(await coordinator.requestTransition(to: .answers) == .succeeded(.answers))
        #expect(await coordinator.requestTransition(to: .recording) == .succeeded(.recording))
        #expect(await coordinator.requestTransition(to: .passive) == .succeeded(.passive))
        #expect(await coordinator.requestTransition(to: .recording) == .succeeded(.recording))
        #expect(await coordinator.requestTransition(to: .answers) == .succeeded(.answers))
        #expect(await coordinator.requestTransition(to: .passive) == .succeeded(.passive))

        let events = await recorder.events

        var lastControllerLabel: String?
        var i = 0
        while i < events.count {
            let event = events[i]
            if event.hasSuffix(".start.begin") {
                let label = String(event.dropLast(".start.begin".count))
                if let lastControllerLabel, lastControllerLabel != label {
                    let stopEndIndex = events.firstIndex(of: "\(lastControllerLabel).stop.end")
                    #expect(stopEndIndex != nil && stopEndIndex! < i)
                }
                lastControllerLabel = label
            }
            i += 1
        }
    }

    @Test func idempotentRepeatDoesNotRestart() async {
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        #expect(await coordinator.requestTransition(to: .answers) == .succeeded(.answers))
        #expect(await coordinator.requestTransition(to: .answers) == .succeeded(.answers))
        #expect(await coordinator.requestTransition(to: .answers) == .succeeded(.answers))

        let events = await recorder.events
        #expect(events.filter { $0 == "answers.start.begin" }.count == 1)
    }

    @Test func answersStartErrorRollsBackToPassive() async {
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(recorder: recorder, answersError: TestError(message: "capture denied"))

        let result = await coordinator.requestTransition(to: .answers)
        guard case .failedToPassive(let reason) = result else {
            Issue.record("expected failedToPassive, got \(result)")
            return
        }
        #expect(reason.contains("capture denied"))
        #expect(await coordinator.currentMode == .passive)

        let events = await recorder.events
        #expect(events.contains("answers.start.threw"))

        #expect(events.contains("answers.stop.begin"))
        #expect(events.contains("answers.stop.end"))
    }

    @Test func recordingStartErrorRollsBackToPassive() async {
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(recorder: recorder, recordingError: TestError(message: "mic denied"))

        let result = await coordinator.requestTransition(to: .recording)
        guard case .failedToPassive = result else {
            Issue.record("expected failedToPassive, got \(result)")
            return
        }
        #expect(await coordinator.currentMode == .passive)
    }

    @Test func stopAlwaysCompletesAndReachesPassive() async {

        let recorder = CallRecorder()
        let coordinator = makeCoordinator(recorder: recorder, recordingStartDelay: .milliseconds(5))

        #expect(await coordinator.requestTransition(to: .recording) == .succeeded(.recording))
        #expect(await coordinator.requestTransition(to: .passive) == .succeeded(.passive))
        #expect(await coordinator.currentMode == .passive)

        let events = await recorder.events
        #expect(events.contains("recording.stop.begin"))
        #expect(events.contains("recording.stop.end"))
    }

    @Test func concurrentSwitchesSerializeWithoutOverlap() async {
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(recorder: recorder, answersStartDelay: .milliseconds(30), recordingStartDelay: .milliseconds(5))

        let first = Task { await coordinator.requestTransition(to: .answers) }
        while !(await recorder.events.contains("answers.start.begin")) {
            await Task.yield()
        }
        async let second = coordinator.requestTransition(to: .recording)
        _ = await (first.value, second)

        let events = await recorder.events
        #expect(events == [
            "answers.start.begin",
            "answers.start.end",
            "answers.stop.begin",
            "answers.stop.end",
            "recording.start.begin",
            "recording.start.end",
        ])

        let finalMode = await coordinator.currentMode
        #expect(finalMode == .recording)
    }

    @Test func shutdownDuringStartingIsBoundedByTimeout() async {
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(recorder: recorder, answersStartDelay: .seconds(3))

        let startingTask = Task { await coordinator.requestTransition(to: .answers) }

        try? await Task.sleep(for: .milliseconds(20))
        let clock = ContinuousClock()
        let start = clock.now
        await coordinator.shutdown(timeout: .milliseconds(200))
        let elapsed = clock.now - start

        #expect(elapsed < .seconds(1))

        startingTask.cancel()
    }

    @Test func noActiveResourcesInPassiveAfterFullCycle() async {
        let recorder = CallRecorder()
        let coordinator = makeCoordinator(recorder: recorder)

        _ = await coordinator.requestTransition(to: .answers)
        _ = await coordinator.requestTransition(to: .passive)
        _ = await coordinator.requestTransition(to: .recording)
        _ = await coordinator.requestTransition(to: .passive)

        let events = await recorder.events
        for label in ["answers", "recording"] {
            let starts = events.filter { $0 == "\(label).start.begin" }.count
            let stops = events.filter { $0 == "\(label).stop.end" }.count
            #expect(starts == stops)
        }
        #expect(await coordinator.currentMode == .passive)
    }

    @Test func runtimeFailureAfterStartTransitionsToPassive() async {
        let recorder = CallRecorder()
        let answers = FakeModeController(label: "answers", recorder: recorder)
        let recording = FakeModeController(label: "recording", recorder: recorder)
        let coordinator = ModeCoordinator(controllers: [.answers: answers, .recording: recording])

        #expect(await coordinator.requestTransition(to: .answers) == .succeeded(.answers))
        answers.emitFailure("websocket_closed")

        try? await Task.sleep(for: .milliseconds(50))
        #expect(await coordinator.currentMode == .passive)
    }
}

@Suite struct ModeCoordinatorBroadcastTests {
    private func modes(_ stream: AsyncStream<ModeState>, until target: [AppMode]) async -> [AppMode] {
        var seen: [AppMode] = []
        for await state in stream {
            if seen.last != state.mode { seen.append(state.mode) }
            if seen.suffix(target.count) == target[...] { break }
        }
        return seen
    }

    @Test func twoReadersBothSeeEveryTransition() async {
        let recorder = CallRecorder()
        let answers = FakeModeController(label: "answers", recorder: recorder)
        let coordinator = ModeCoordinator(controllers: [.answers: answers])
        let first = coordinator.stateUpdates(subscriber: "switcher")
        let second = coordinator.stateUpdates(subscriber: "overlay")
        _ = await coordinator.requestTransition(to: .answers)
        _ = await coordinator.requestTransition(to: .passive)
        let expected: [AppMode] = [.passive, .answers, .passive]
        #expect(await modes(first, until: expected) == expected)
        #expect(await modes(second, until: expected) == expected)
    }

    @Test func lateReaderSeesCurrentState() async {
        let recorder = CallRecorder()
        let answers = FakeModeController(label: "answers", recorder: recorder)
        let coordinator = ModeCoordinator(controllers: [.answers: answers])
        _ = await coordinator.requestTransition(to: .answers)
        var iterator = coordinator.stateUpdates(subscriber: "late").makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.mode == .answers)
    }
}
