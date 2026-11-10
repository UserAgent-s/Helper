import Testing
@testable import Domain

@Suite struct ProfileKeywordExtractorTests {
    @Test func ranksByFrequencyThenFirstSeenAndKeepsSpelling() {
        let docs = [
            ProfileDocument(relativePath: "01.md", text: "Kafka, Symfony; Symfony и PostgreSQL. symfony"),
            ProfileDocument(relativePath: "02.md", text: "PostgreSQL, Go1.22, C#, C++ и Node.js"),
        ]
        let keywords = ProfileKeywordExtractor.extract(from: docs)
        #expect(Array(keywords.prefix(2)) == ["Symfony", "PostgreSQL"])
        #expect(keywords.contains("Kafka"))
        #expect(keywords.contains("Go1.22"))
        #expect(keywords.contains("C#"))
        #expect(keywords.contains("C++"))
        #expect(keywords.contains("Node.js"))
    }

    @Test func skipsCyrillicLowercaseStopwordsAndMarkdownNoise() {
        let docs = [ProfileDocument(relativePath: "a.md", text: "# Опыт\n- работал в компании\n- the and MD PDF https://x.com 2024 42")]
        #expect(ProfileKeywordExtractor.extract(from: docs).isEmpty)
    }

    @Test func respectsLimit() {
        let text = (1...100).map { "Term\($0)" }.joined(separator: " ")
        let keywords = ProfileKeywordExtractor.extract(from: [ProfileDocument(relativePath: "a.md", text: text)], limit: 10)
        #expect(keywords.count == 10)
        #expect(keywords.first == "Term1")
    }

    @Test func sanitizedRemovesForbiddenCharactersDuplicatesAndOverlong() {
        let result = ProfileKeywordExtractor.sanitized(["<AC-42>", "AC-42", "line\nbreak", "  ", String(repeating: "x", count: 49), "ok"], limit: 10)
        #expect(result == ["AC-42", "line break", "ok"])
        #expect(ProfileKeywordExtractor.sanitized(["a", "b", "c"], limit: 2) == ["a", "b"])
    }
}
