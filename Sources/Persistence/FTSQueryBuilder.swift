import Foundation

public struct FTSQuery: Sendable, Equatable {
    public let words: String
    public let trigrams: String?

    public init(words: String, trigrams: String?) {
        self.words = words
        self.trigrams = trigrams
    }
}

public enum FTSQueryBuilder {
    public static let maxTokens = 8
    public static let minimumTrigramLength = 3

    public static func tokens(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty {
                let token = fold(String(current))
                if !tokens.contains(token) {
                    tokens.append(token)
                }
                current = String.UnicodeScalarView()
            }
        }
        for scalar in raw.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return Array(tokens.prefix(maxTokens))
    }

    public static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    public static func build(_ raw: String, aliases: [String: [String]] = [:]) -> FTSQuery? {
        let groups = tokens(raw).map { token in
            [token] + (aliases[token] ?? []).map(fold).filter { $0 != token }
        }
        guard !groups.isEmpty else { return nil }
        let words = groups.map { group in
            disjunction(group.map { quoted($0) + "*" })
        }.joined(separator: " AND ")
        let trigramGroups = groups.map { group in
            group.filter { $0.count >= minimumTrigramLength }
        }
        let trigrams = trigramGroups.contains(where: \.isEmpty) ? nil : trigramGroups.map { group in
            disjunction(group.map(quoted))
        }.joined(separator: " AND ")
        return FTSQuery(words: words, trigrams: trigrams)
    }

    public static func build(_ raw: String, database: SQLiteDatabase) async throws -> FTSQuery? {
        let found = tokens(raw)
        guard !found.isEmpty else { return nil }
        try await database.ensureReady()
        let placeholders = Array(repeating: "?", count: found.count).joined(separator: ", ")
        let pairs = try await database.query(
            "SELECT lower(term), alias FROM search_aliases WHERE term IN (\(placeholders)) ORDER BY term, alias",
            found.map(SQLiteValue.text),
            map: { row in (row.string(0) ?? "", row.string(1) ?? "") }
        )
        var aliases: [String: [String]] = [:]
        for (term, alias) in pairs where !alias.isEmpty {
            aliases[fold(term), default: []].append(alias)
        }
        return build(raw, aliases: aliases)
    }

    static func quoted(_ token: String) -> String {
        "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func disjunction(_ terms: [String]) -> String {
        terms.count == 1 ? terms[0] : "(" + terms.joined(separator: " OR ") + ")"
    }
}

extension FTSQueryBuilder {
    static func rowids(index table: String, _ query: FTSQuery) -> String {
        let words = "SELECT rowid FROM \(table)_fts WHERE \(table)_fts MATCH ?"
        guard query.trigrams != nil else { return words }
        return words + " UNION SELECT rowid FROM \(table)_trgm WHERE \(table)_trgm MATCH ?"
    }

    static func parameters(_ query: FTSQuery) -> [SQLiteValue] {
        [.text(query.words)] + (query.trigrams.map { [SQLiteValue.text($0)] } ?? [])
    }
}
