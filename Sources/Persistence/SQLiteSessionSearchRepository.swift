import Domain
import Foundation

public final class SQLiteSessionSearchRepository: SessionSearching, Sendable {
    public static let snippetTokens = 12
    public static let hitsPerSession = 3
    public static let rowLimit = 400

    struct Target {
        let source: SessionSearchSource
        let table: String
        let sessionColumn: String
        let timeColumn: String
        let words: String
        let trigrams: String?
        let filter: String
    }

    static let targets: [Target] = [
        Target(source: .utterance, table: "utterances", sessionColumn: "meeting_id", timeColumn: "captured_at", words: "utterances_fts", trigrams: "utterances_trgm", filter: ""),
        Target(source: .questionAnswer, table: "qa_entries", sessionColumn: "session_id", timeColumn: "asked_at", words: "qa_entries_fts", trigrams: "qa_entries_trgm", filter: " AND c.session_id IS NOT NULL"),
        Target(source: .screenText, table: "screen_contexts", sessionColumn: "session_id", timeColumn: "captured_at", words: "screen_contexts_fts", trigrams: "screen_contexts_trgm", filter: ""),
        Target(source: .expansion, table: "deep_expansions", sessionColumn: "session_id", timeColumn: "requested_at", words: "deep_expansions_fts", trigrams: "deep_expansions_trgm", filter: ""),
        Target(source: .bookmark, table: "bookmarks", sessionColumn: "session_id", timeColumn: "marked_at", words: "bookmarks_fts", trigrams: nil, filter: ""),
    ]

    private struct Row {
        let source: SessionSearchSource
        let itemID: String
        let sessionKey: String
        let occurredAt: Date?
        let snippet: String
        let rank: Double
    }

    private let connection: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        connection = database
    }

    public func search(query: String, limit: Int) async throws -> [SessionSearchResult] {
        guard limit > 0, let fts = try await FTSQueryBuilder.build(query, database: connection) else { return [] }
        var selects: [String] = []
        var params: [SQLiteValue] = []
        for target in Self.targets {
            selects.append(Self.select(target, index: target.words, pass: 0))
            params.append(.text(fts.words))
            if let trigramIndex = target.trigrams, let trigrams = fts.trigrams {
                selects.append(Self.select(target, index: trigramIndex, pass: 1))
                params.append(.text(trigrams))
            }
        }
        let rows = try await connection.query(
            selects.joined(separator: " UNION ALL ") + " ORDER BY 7, 6 LIMIT ?",
            params + [.int(Self.rowLimit)],
            map: Self.rowMapper
        )
        var seen = Set<String>()
        var order: [String] = []
        var grouped: [String: [Row]] = [:]
        for row in rows.compactMap({ $0 }) {
            guard seen.insert(row.source.rawValue + "|" + row.itemID).inserted else { continue }
            if grouped[row.sessionKey] == nil {
                guard order.count < limit else { continue }
                order.append(row.sessionKey)
            }
            if grouped[row.sessionKey, default: []].count < Self.hitsPerSession {
                grouped[row.sessionKey, default: []].append(row)
            }
        }
        guard !order.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: order.count).joined(separator: ", ")
        let headers = try await connection.query(
            "SELECT id, kind, title, started_at FROM meetings WHERE id IN (\(placeholders))",
            order.map(SQLiteValue.text),
            map: { row in (row.string(0) ?? "", row.string(1), row.string(2), row.string(3)) }
        )
        var byKey: [String: (String?, String?, String?)] = [:]
        for header in headers {
            byKey[header.0] = (header.1, header.2, header.3)
        }
        return order.compactMap { key in
            guard let header = byKey[key], let uuid = UUID(uuidString: key), let startedAt = Self.parse(header.2) else { return nil }
            let sessionID = SessionID(rawValue: uuid)
            let hits = (grouped[key] ?? []).map { row in
                SessionSearchHit(sessionID: sessionID, source: row.source, itemID: row.itemID, snippet: row.snippet, occurredAt: row.occurredAt, rank: row.rank)
            }
            return SessionSearchResult(sessionID: sessionID, kind: header.0.flatMap(SessionKind.init(rawValue:)) ?? .recording, title: header.1, startedAt: startedAt, hits: hits)
        }
    }

    static func select(_ target: Target, index: String, pass: Int) -> String {
        """
        SELECT '\(target.source.rawValue)', c.id, c.\(target.sessionColumn), c.\(target.timeColumn), \
        snippet(\(index), -1, '«', '»', '…', \(snippetTokens)), bm25(\(index)), \(pass) \
        FROM \(index) JOIN \(target.table) c ON c.rowid = \(index).rowid \
        WHERE \(index) MATCH ?\(target.filter)
        """
    }

    private static func rowMapper(_ row: SQLiteRow) -> Row? {
        guard let source = row.string(0).flatMap(SessionSearchSource.init(rawValue:)), let itemID = row.string(1), let sessionKey = row.string(2) else { return nil }
        return Row(source: source, itemID: itemID, sessionKey: sessionKey, occurredAt: parse(row.string(3)), snippet: row.string(4) ?? "", rank: row.double(5) ?? 0)
    }

    private static func parse(_ string: String?) -> Date? {
        string.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}
