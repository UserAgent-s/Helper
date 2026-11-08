import Domain
import Foundation
@testable import Summary

actor FakeResponsesAPITransport: ResponsesAPITransport {
    private(set) var receivedRequestBodies: [Data] = []
    var scriptedContents: [SummaryContent] = []
    private var callIndex = 0
    var error: Error?

    func setScriptedContents(_ contents: [SummaryContent]) {
        scriptedContents = contents
    }

    func setError(_ error: Error?) {
        self.error = error
    }

    struct NoScriptedContent: Error {}

    func createResponse(requestBody: Data, apiKey: String) async throws -> Data {
        receivedRequestBodies.append(requestBody)
        if let error { throw error }
        guard !scriptedContents.isEmpty else { throw NoScriptedContent() }

        let content = scriptedContents[min(callIndex, scriptedContents.count - 1)]
        callIndex += 1

        let encoder = JSONEncoder()
        let contentData = try encoder.encode(content)
        let contentString = String(data: contentData, encoding: .utf8) ?? "{}"

        let responseObject: [String: Any] = [
            "output_text": contentString,
            "usage": ["input_tokens": 100, "output_tokens": 50, "total_tokens": 150],
        ]
        return try JSONSerialization.data(withJSONObject: responseObject)
    }
}

struct FakeSecretStore: SecretStoring {
    var apiKey: String?

    func store(apiKey: String) throws {}

    func retrieveAPIKey() throws -> String? {
        apiKey
    }

    func deleteAPIKey() throws {}
}

func makeSampleContent(title: String = "Планёрка") -> SummaryContent {
    SummaryContent(
        title: title,
        overview: "Обсудили статус проекта",
        topics: [SummaryContent.Topic(name: "Статус", startMs: 0, endMs: 60_000)],
        decisions: [SummaryContent.EvidencedStatement(text: "Перенести релиз", evidenceTimestampMs: 12_000)],
        actionItems: [SummaryContent.ActionItem(task: "Обновить план", owner: "Иван", deadline: "пятница", evidenceTimestampMs: 20_000)],
        openQuestions: ["Кто отвечает за миграцию?"],
        risks: ["Задержка поставщика"],
        keyFacts: ["Бюджет не изменился"],
        shortSummary: "Релиз переносится, план обновит Иван к пятнице."
    )
}
