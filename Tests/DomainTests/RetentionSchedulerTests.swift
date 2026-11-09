import Foundation
import Testing
@testable import Domain

private actor RecordingSweeper: RetentionSweeping {
    private(set) var calls: [(RetentionPolicy, SessionID?)] = []
    var failing = false

    func setFailing() { failing = true }

    func sweep(policy: RetentionPolicy, excluding active: SessionID?, now: Date) async throws -> RetentionSweepReport {
        calls.append((policy, active))
        if failing { throw CancellationError() }
        return RetentionSweepReport(deletedQuestionAnswerCount: 1)
    }
}

private final class PolicyBox: @unchecked Sendable {
    var policy = RetentionPolicy(days: nil)
}

@Suite struct RetentionSchedulerTests {
    @Test func policyNormalizesAndComputesCutoff() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(RetentionPolicy(days: 0).days == nil)
        #expect(RetentionPolicy(days: -3).isNoop)
        #expect(RetentionPolicy(days: nil).cutoff(now: now) == nil)
        #expect(RetentionPolicy(days: 2).cutoff(now: now) == now.addingTimeInterval(-172_800))
        #expect(!RetentionPolicy(days: nil, keepScreenTexts: false).isNoop)
    }

    @Test func schedulerSkipsNoopAndPassesActiveSession() async {
        let sweeper = RecordingSweeper()
        let box = PolicyBox()
        let active = SessionID()
        let scheduler = RetentionScheduler(sweeper: sweeper, policy: { box.policy }, activeSession: { active })

        #expect(await scheduler.runOnce() == nil)
        #expect(await sweeper.calls.isEmpty)

        box.policy = RetentionPolicy(days: 30)
        #expect(await scheduler.runOnce() == RetentionSweepReport(deletedQuestionAnswerCount: 1))
        let calls = await sweeper.calls
        #expect(calls.count == 1)
        #expect(calls.first?.0 == RetentionPolicy(days: 30))
        #expect(calls.first?.1 == active)

        await sweeper.setFailing()
        #expect(await scheduler.runOnce() == nil)
        #expect(await scheduler.failureCount == 1)
        #expect(await scheduler.runCount == 2)
    }
}
