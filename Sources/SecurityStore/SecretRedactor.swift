import Foundation

public enum SecretRedactor {
    private static let knownKeyPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "sk-[A-Za-z0-9_-]{16,}"),
        try! NSRegularExpression(pattern: "Bearer\\s+[A-Za-z0-9._-]{16,}"),
    ]

    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in knownKeyPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: "[REDACTED]")
        }
        return result
    }
}
