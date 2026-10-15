import Domain
import Foundation

public struct SummaryContent: Codable, Sendable, Equatable {
    public struct Topic: Codable, Sendable, Equatable {
        public let name: String
        public let startMs: Int
        public let endMs: Int

        enum CodingKeys: String, CodingKey {
            case name
            case startMs = "start_ms"
            case endMs = "end_ms"
        }

        public init(name: String, startMs: Int, endMs: Int) {
            self.name = name
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    public struct EvidencedStatement: Codable, Sendable, Equatable {
        public let text: String
        public let evidenceTimestampMs: Int?

        enum CodingKeys: String, CodingKey {
            case text
            case evidenceTimestampMs = "evidence_timestamp_ms"
        }

        public init(text: String, evidenceTimestampMs: Int?) {
            self.text = text
            self.evidenceTimestampMs = evidenceTimestampMs
        }
    }

    public struct ActionItem: Codable, Sendable, Equatable {
        public let task: String
        public let owner: String?
        public let deadline: String?
        public let evidenceTimestampMs: Int?

        enum CodingKeys: String, CodingKey {
            case task, owner, deadline
            case evidenceTimestampMs = "evidence_timestamp_ms"
        }

        public init(task: String, owner: String?, deadline: String?, evidenceTimestampMs: Int?) {
            self.task = task
            self.owner = owner
            self.deadline = deadline
            self.evidenceTimestampMs = evidenceTimestampMs
        }
    }

    public let title: String
    public let overview: String
    public let topics: [Topic]
    public let decisions: [EvidencedStatement]
    public let actionItems: [ActionItem]
    public let openQuestions: [String]
    public let risks: [String]
    public let keyFacts: [String]
    public let shortSummary: String

    enum CodingKeys: String, CodingKey {
        case title, overview, topics, decisions, risks
        case actionItems = "action_items"
        case openQuestions = "open_questions"
        case keyFacts = "key_facts"
        case shortSummary = "short_summary"
    }

    public init(
        title: String,
        overview: String,
        topics: [Topic],
        decisions: [EvidencedStatement],
        actionItems: [ActionItem],
        openQuestions: [String],
        risks: [String],
        keyFacts: [String],
        shortSummary: String
    ) {
        self.title = title
        self.overview = overview
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.risks = risks
        self.keyFacts = keyFacts
        self.shortSummary = shortSummary
    }
}

public enum SummaryJSONSchema {
    public static let version = 1

    public static func makeJSONSchemaDictionary() -> [String: Any] {
        [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "overview": ["type": "string"],
            "topics": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "start_ms": ["type": "integer"],
                        "end_ms": ["type": "integer"],
                    ],
                    "required": ["name", "start_ms", "end_ms"],
                    "additionalProperties": false,
                ],
            ],
            "decisions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "evidence_timestamp_ms": ["type": ["integer", "null"]],
                    ],
                    "required": ["text", "evidence_timestamp_ms"],
                    "additionalProperties": false,
                ],
            ],
            "action_items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "task": ["type": "string"],
                        "owner": ["type": ["string", "null"]],
                        "deadline": ["type": ["string", "null"]],
                        "evidence_timestamp_ms": ["type": ["integer", "null"]],
                    ],
                    "required": ["task", "owner", "deadline", "evidence_timestamp_ms"],
                    "additionalProperties": false,
                ],
            ],
            "open_questions": ["type": "array", "items": ["type": "string"]],
            "risks": ["type": "array", "items": ["type": "string"]],
            "key_facts": ["type": "array", "items": ["type": "string"]],
            "short_summary": ["type": "string"],
        ],
        "required": ["title", "overview", "topics", "decisions", "action_items", "open_questions", "risks", "key_facts", "short_summary"],
        "additionalProperties": false,
        ]
    }
}

public enum SummaryMarkdownRenderer {
    public static func render(_ content: SummaryContent, headers: SummaryMarkdownHeaders = .russianDefault) -> String {
        var lines: [String] = []
        lines.append("# \(content.title)")
        lines.append("")
        lines.append(content.overview)
        lines.append("")
        lines.append("## \(headers.shortSummary)")
        lines.append(content.shortSummary)

        if !content.topics.isEmpty {
            lines.append("")
            lines.append("## \(headers.topics)")
            for topic in content.topics {
                lines.append("- \(topic.name) (\(formatTimestamp(topic.startMs))–\(formatTimestamp(topic.endMs)))")
            }
        }

        if !content.decisions.isEmpty {
            lines.append("")
            lines.append("## \(headers.decisions)")
            for decision in content.decisions {
                lines.append("- \(decision.text)\(timestampSuffix(decision.evidenceTimestampMs, headers: headers))")
            }
        }

        if !content.actionItems.isEmpty {
            lines.append("")
            lines.append("## \(headers.actionItems)")
            for item in content.actionItems {
                var line = "- \(item.task)"
                if let owner = item.owner { line += " — \(owner)" }
                if let deadline = item.deadline { line += " (до \(deadline))" }
                line += timestampSuffix(item.evidenceTimestampMs, headers: headers)
                lines.append(line)
            }
        }

        if !content.openQuestions.isEmpty {
            lines.append("")
            lines.append("## \(headers.openQuestions)")
            for question in content.openQuestions { lines.append("- \(question)") }
        }

        if !content.risks.isEmpty {
            lines.append("")
            lines.append("## \(headers.risks)")
            for risk in content.risks { lines.append("- \(risk)") }
        }

        if !content.keyFacts.isEmpty {
            lines.append("")
            lines.append("## \(headers.keyFacts)")
            for fact in content.keyFacts { lines.append("- \(fact)") }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func timestampSuffix(_ ms: Int?, headers: SummaryMarkdownHeaders) -> String {
        guard let ms else { return " (\(headers.noTimestampFound))" }
        return " [\(formatTimestamp(ms))]"
    }

    private static func formatTimestamp(_ ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
