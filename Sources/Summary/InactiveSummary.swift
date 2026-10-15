import Domain

public struct InactiveSummaryGenerating: SummaryGenerating {
    public init() {}

    public func summarize(meetingID: MeetingID, headers: SummaryMarkdownHeaders) async throws -> MeetingSummary {
        throw BootstrapUnavailableError.notYetImplemented("SummaryGenerating подключается на этапе 09")
    }
}
