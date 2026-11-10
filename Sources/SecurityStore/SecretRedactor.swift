import Foundation

public enum SecretRedactor {
    private static let knownKeyPatterns: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: "(?i)(x-api-key\\\\?\"?\\s*[:=]\\s*\\\\?\"?)[^\\s\",}\\\\]+"), "$1[REDACTED]"),
        (try! NSRegularExpression(pattern: "sk-ant-[A-Za-z0-9_-]{8,}"), "[REDACTED]"),
        (try! NSRegularExpression(pattern: "sk-[A-Za-z0-9_-]{16,}"), "[REDACTED]"),
        (try! NSRegularExpression(pattern: "Bearer\\s+[A-Za-z0-9._-]{16,}"), "[REDACTED]"),
    ]

    public static func redact(_ text: String) -> String {
        var result = text
        for (pattern, template) in knownKeyPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
