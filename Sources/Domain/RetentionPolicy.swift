import Foundation

public struct RetentionPolicy: Sendable, Equatable {
    public static let sweepInterval: Duration = .seconds(86_400)

    public let days: Int?
    public let keepScreenTexts: Bool

    public init(days: Int?, keepScreenTexts: Bool = true) {
        self.days = days.flatMap { $0 > 0 ? $0 : nil }
        self.keepScreenTexts = keepScreenTexts
    }

    public func cutoff(now: Date) -> Date? {
        days.map { now.addingTimeInterval(-Double($0) * 86_400) }
    }

    public var isNoop: Bool { days == nil && keepScreenTexts }
}

public struct RetentionSweepReport: Sendable, Equatable {
    public var deletedMeetingIDs: [MeetingID]
    public var deletedQuestionAnswerCount: Int
    public var deletedScreenContextCount: Int

    public init(deletedMeetingIDs: [MeetingID] = [], deletedQuestionAnswerCount: Int = 0, deletedScreenContextCount: Int = 0) {
        self.deletedMeetingIDs = deletedMeetingIDs
        self.deletedQuestionAnswerCount = deletedQuestionAnswerCount
        self.deletedScreenContextCount = deletedScreenContextCount
    }
}

public protocol RetentionSweeping: Sendable {
    func sweep(policy: RetentionPolicy, excluding active: SessionID?, now: Date) async throws -> RetentionSweepReport
}

public actor RetentionScheduler {
    private let sweeper: any RetentionSweeping
    private let policy: @Sendable () async -> RetentionPolicy
    private let activeSession: @Sendable () async -> SessionID?
    private let now: @Sendable () -> Date
    private(set) public var lastReport: RetentionSweepReport?
    private(set) public var runCount = 0
    private(set) public var failureCount = 0

    public init(
        sweeper: any RetentionSweeping,
        policy: @escaping @Sendable () async -> RetentionPolicy,
        activeSession: @escaping @Sendable () async -> SessionID?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sweeper = sweeper
        self.policy = policy
        self.activeSession = activeSession
        self.now = now
    }

    @discardableResult
    public func runOnce() async -> RetentionSweepReport? {
        let current = await policy()
        guard !current.isNoop else { return nil }
        runCount += 1
        do {
            let report = try await sweeper.sweep(policy: current, excluding: await activeSession(), now: now())
            lastReport = report
            return report
        } catch {
            failureCount += 1
            return nil
        }
    }

    public func run(interval: Duration = RetentionPolicy.sweepInterval) async {
        while !Task.isCancelled {
            await runOnce()
            try? await Task.sleep(for: interval)
        }
    }
}
