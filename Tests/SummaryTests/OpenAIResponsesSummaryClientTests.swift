import Domain
import Foundation
import Testing
import Persistence
@testable import Summary

@Suite struct OpenAIResponsesSummaryClientTests {

    private func completedMeeting(segmentCount: Int, textLength: Int = 20) async throws -> (any MeetingRepository, MeetingID) {
        let repository = SQLiteMeetingRepository(path: ":memory:")
        let id = try await repository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)
        for i in 0..<segmentCount {
            try await repository.appendSegment(
                TranscribedSegment(
                    text: String(repeating: "слово ", count: textLength) + "\(i)",
                    startMs: i * 1000,
                    endMs: i * 1000 + 900,
                    source: i.isMultiple(of: 2) ? .local : .remote
                ),
                meetingID: id
            )
        }
        try await repository.finish(meetingID: id, endedAt: Date())
        return (repository, id)
    }

    @Test func missingAPIKeyThrowsNotAuthenticatedBeforeAnyNetworkCall() async throws {
        let (repository, id) = try await completedMeeting(segmentCount: 1)
        let transport = FakeResponsesAPITransport()
        let client = OpenAIResponsesSummaryClient(
            secretStoring: FakeSecretStore(apiKey: nil),
            meetingRepository: repository,
            transport: transport
        )

        await #expect(throws: SummaryGeneratingError.notAuthenticated) {
            _ = try await client.summarize(meetingID: id, headers: .russianDefault)
        }
        #expect(await transport.receivedRequestBodies.isEmpty)
    }

    @Test func meetingStillRecordingIsRejected() async throws {
        let repository = SQLiteMeetingRepository(path: ":memory:")
        let id = try await repository.createMeeting(startedAt: Date(), sourceAppBundleID: nil)
        let client = OpenAIResponsesSummaryClient(
            secretStoring: FakeSecretStore(apiKey: "sk-test"),
            meetingRepository: repository,
            transport: FakeResponsesAPITransport()
        )

        await #expect(throws: SummaryGeneratingError.meetingNotCompleted) {
            _ = try await client.summarize(meetingID: id, headers: .russianDefault)
        }
    }

    @Test func singleChunkTranscriptCallsTransportOnceAndReturnsParsedContent() async throws {
        let (repository, id) = try await completedMeeting(segmentCount: 2)
        let transport = FakeResponsesAPITransport()
        await transport.setScriptedContents([makeSampleContent()])
        let client = OpenAIResponsesSummaryClient(
            secretStoring: FakeSecretStore(apiKey: "sk-test"),
            meetingRepository: repository,
            transport: transport,
            maxCharactersPerChunk: 100_000
        )

        let summary = try await client.summarize(meetingID: id, headers: .russianDefault)

        #expect(await transport.receivedRequestBodies.count == 1)
        #expect(summary.renderedMarkdown.contains("Планёрка"))
        #expect(summary.usageTokens == 150)
    }

    @Test func longTranscriptIsChunkedAndMergedWithOneExtraCall() async throws {
        let (repository, id) = try await completedMeeting(segmentCount: 4, textLength: 200)
        let transport = FakeResponsesAPITransport()
        await transport.setScriptedContents([
            makeSampleContent(title: "Часть 1"),
            makeSampleContent(title: "Часть 2"),
            makeSampleContent(title: "Итог"),
        ])
        let client = OpenAIResponsesSummaryClient(
            secretStoring: FakeSecretStore(apiKey: "sk-test"),
            meetingRepository: repository,
            transport: transport,
            maxCharactersPerChunk: 2_500
        )

        let summary = try await client.summarize(meetingID: id, headers: .russianDefault)

        let callCount = await transport.receivedRequestBodies.count
        #expect(callCount == 3)
        #expect(summary.renderedMarkdown.contains("Итог"))
    }

    @Test func evidenceTimestampsSurviveRoundTrip() async throws {
        let (repository, id) = try await completedMeeting(segmentCount: 1)
        let transport = FakeResponsesAPITransport()
        await transport.setScriptedContents([makeSampleContent()])
        let client = OpenAIResponsesSummaryClient(
            secretStoring: FakeSecretStore(apiKey: "sk-test"),
            meetingRepository: repository,
            transport: transport,
            maxCharactersPerChunk: 100_000
        )

        let summary = try await client.summarize(meetingID: id, headers: .russianDefault)
        let decoded = try JSONDecoder().decode(SummaryContent.self, from: Data(summary.contentJSON.utf8))

        #expect(decoded.decisions.first?.evidenceTimestampMs == 12_000)
        #expect(decoded.actionItems.first?.evidenceTimestampMs == 20_000)
    }

    @Test func requestBodyContainsOnlyTextNeverAudio() async throws {
        let (repository, id) = try await completedMeeting(segmentCount: 1)
        let transport = FakeResponsesAPITransport()
        await transport.setScriptedContents([makeSampleContent()])
        let client = OpenAIResponsesSummaryClient(
            secretStoring: FakeSecretStore(apiKey: "sk-test"),
            meetingRepository: repository,
            transport: transport,
            maxCharactersPerChunk: 100_000
        )

        _ = try await client.summarize(meetingID: id, headers: .russianDefault)

        let bodies = await transport.receivedRequestBodies
        let json = try JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any]
        let inputArray = json?["input"] as? [[String: Any]]
        #expect(inputArray?.allSatisfy { ($0["content"] as? String) != nil } == true)
    }

    @Test func cancellationBeforeRequestNeverCallsTransport() async throws {
        let (repository, id) = try await completedMeeting(segmentCount: 1)
        let transport = FakeResponsesAPITransport()
        let client = OpenAIResponsesSummaryClient(
            secretStoring: FakeSecretStore(apiKey: "sk-test"),
            meetingRepository: repository,
            transport: transport
        )

        let task = Task {
            try await client.summarize(meetingID: id, headers: .russianDefault)
        }
        task.cancel()

        await #expect(throws: (any Error).self) {
            _ = try await task.value
        }
    }
}
