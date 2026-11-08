import Foundation
import Testing
@testable import Summary

@Suite struct SummaryContentSchemaTests {

    @Test func encodesUsingSnakeCaseKeysMatchingTheDocumentedSchema() throws {
        let content = makeSampleContent()
        let data = try JSONEncoder().encode(content)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["action_items"] != nil)
        #expect(json?["open_questions"] != nil)
        #expect(json?["key_facts"] != nil)
        #expect(json?["short_summary"] != nil)
    }

    @Test func decodesNullEvidenceTimestampAsNilRatherThanFabricating() throws {
        let json = """
        {
            "title": "T", "overview": "O", "topics": [],
            "decisions": [{"text": "Решение без таймкода", "evidence_timestamp_ms": null}],
            "action_items": [], "open_questions": [], "risks": [], "key_facts": [],
            "short_summary": "S"
        }
        """
        let content = try JSONDecoder().decode(SummaryContent.self, from: Data(json.utf8))
        #expect(content.decisions.first?.evidenceTimestampMs == nil)
    }

    @Test func markdownMarksMissingEvidenceTimestampExplicitly() {
        let content = SummaryContent(
            title: "T", overview: "O", topics: [],
            decisions: [SummaryContent.EvidencedStatement(text: "Без источника", evidenceTimestampMs: nil)],
            actionItems: [], openQuestions: [], risks: [], keyFacts: [], shortSummary: "S"
        )
        let markdown = SummaryMarkdownRenderer.render(content)
        #expect(markdown.contains("таймкод не найден"))
    }

    @Test func jsonSchemaDictionaryIsValidJSONSerializable() throws {
        let schema = SummaryJSONSchema.makeJSONSchemaDictionary()
        #expect(JSONSerialization.isValidJSONObject(schema))
    }
}
