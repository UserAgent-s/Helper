import Foundation

public enum ProfileKeywordExtractor {
    public static let defaultLimit = 40
    public static let maxKeywordLength = 48

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "from", "this", "that", "into", "over", "about", "what", "when",
        "md", "pdf", "txt", "http", "https", "www", "com", "cv", "todo", "ok", "faq", "i", "a", "an",
    ]

    public static func extract(from documents: [ProfileDocument], limit: Int = defaultLimit) -> [String] {
        var counts: [String: Int] = [:]
        var spelling: [String: String] = [:]
        var firstSeen: [String: Int] = [:]
        var order = 0
        for document in documents {
            for token in candidateTokens(in: document.text) {
                let key = token.lowercased()
                guard !stopwords.contains(key) else { continue }
                counts[key, default: 0] += 1
                if spelling[key] == nil {
                    spelling[key] = token
                    firstSeen[key] = order
                    order += 1
                }
            }
        }
        let ranked = counts.keys.sorted { lhs, rhs in
            let l = counts[lhs] ?? 0
            let r = counts[rhs] ?? 0
            if l != r { return l > r }
            return (firstSeen[lhs] ?? 0) < (firstSeen[rhs] ?? 0)
        }
        return ranked.prefix(max(0, limit)).compactMap { spelling[$0] }
    }

    public static func sanitized(_ keywords: [String], limit: Int = defaultLimit) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for keyword in keywords {
            let cleaned = keyword
                .components(separatedBy: CharacterSet(charactersIn: "<>\r\n"))
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, cleaned.count <= maxKeywordLength else { continue }
            guard seen.insert(cleaned.lowercased()).inserted else { continue }
            result.append(cleaned)
            if result.count == limit { break }
        }
        return result
    }

    static func candidateTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            if isCandidate(trimmed) { tokens.append(trimmed) }
            current = ""
        }
        for scalar in text.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || "+#.-".unicodeScalars.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    private static func isCandidate(_ token: String) -> Bool {
        guard token.count >= 2, token.count <= maxKeywordLength else { return false }
        guard let first = token.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        let hasUpper = token.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }
        let hasDigitOrSymbol = token.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) || "+#".unicodeScalars.contains($0) }
        return hasUpper || hasDigitOrSymbol
    }
}
