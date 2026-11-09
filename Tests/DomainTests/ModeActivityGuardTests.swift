import Foundation
import Testing
@testable import Domain

final class RecordingSleepPreventing: SleepPreventing, @unchecked Sendable {
    private let lock = NSLock()
    private var begun = 0
    private var ended = 0

    var counts: (begun: Int, ended: Int) {
        lock.withLock { (begun, ended) }
    }

    func begin(reason: String) -> any SleepPreventionToken {
        lock.withLock { begun += 1 }
        return Token(owner: self)
    }

    fileprivate func markEnded() {
        lock.withLock { ended += 1 }
    }

    private struct Token: SleepPreventionToken {
        let owner: RecordingSleepPreventing
        func end() { owner.markEnded() }
    }
}

@Suite struct ModeActivityGuardTests {
    private func state(_ mode: AppMode, _ phase: ModePhase) -> ModeState {
        ModeState(mode: mode, phase: phase, startedAt: nil, userFacingError: nil)
    }

    @Test func holdsSleepAssertionOnlyWhileAnswersOrRecordingIsActive() async {
        let preventing = RecordingSleepPreventing()
        let guardian = ModeActivityGuard(preventing: preventing)
        await guardian.apply(state(.passive, .idle))
        #expect(await !guardian.isHolding)
        await guardian.apply(state(.answers, .starting))
        await guardian.apply(state(.answers, .active))
        #expect(await guardian.isHolding)
        #expect(preventing.counts == (1, 0))
        await guardian.apply(state(.answers, .stopping))
        #expect(await !guardian.isHolding)
        #expect(preventing.counts == (1, 1))
        await guardian.apply(state(.recording, .active))
        await guardian.apply(state(.answers, .failed))
        #expect(preventing.counts == (2, 2))
        await guardian.apply(state(.passive, .idle))
        #expect(preventing.counts == (2, 2))
    }

    @Test func followsStateStreamAndReleasesOnStop() async {
        let preventing = RecordingSleepPreventing()
        let guardian = ModeActivityGuard(preventing: preventing)
        let (states, continuation) = AsyncStream<ModeState>.makeStream()
        await guardian.start(states: states)
        continuation.yield(state(.answers, .active))
        for _ in 0..<200 where await !guardian.isHolding {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await guardian.isHolding)
        await guardian.stop()
        #expect(await !guardian.isHolding)
        #expect(preventing.counts == (1, 1))
        continuation.finish()
    }

    @Test func processInfoTokenEndsOnce() {
        let token = ProcessInfoSleepPreventing().begin(reason: "test")
        token.end()
        token.end()
    }

    @Test func sessionHoldsAssertionInPassiveUntilIdle() async {
        let preventing = RecordingSleepPreventing()
        let guardian = ModeActivityGuard(preventing: preventing)
        let id = SessionID()
        await guardian.apply(SessionState.active(sessionID: id, startedAt: Date(), mode: nil))
        #expect(await guardian.isHolding)
        await guardian.apply(state(.answers, .active))
        await guardian.apply(state(.passive, .idle))
        #expect(await guardian.isHolding)
        #expect(preventing.counts == (1, 0))
        await guardian.apply(SessionState.finalizing(sessionID: id))
        #expect(await guardian.isHolding)
        await guardian.apply(SessionState.idle)
        #expect(await !guardian.isHolding)
        #expect(preventing.counts == (1, 1))
    }

    @Test func modeStillHoldsAfterSessionEnds() async {
        let preventing = RecordingSleepPreventing()
        let guardian = ModeActivityGuard(preventing: preventing)
        let (sessions, continuation) = AsyncStream<SessionState>.makeStream()
        await guardian.observeSessions(sessions)
        await guardian.apply(state(.recording, .active))
        continuation.yield(.active(sessionID: SessionID(), startedAt: Date(), mode: .recording))
        continuation.yield(.idle)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await guardian.isHolding)
        await guardian.apply(state(.passive, .idle))
        #expect(await !guardian.isHolding)
        await guardian.stop()
        #expect(preventing.counts == (1, 1))
    }
}
