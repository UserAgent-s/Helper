import Testing
@testable import SecurityStore

@Suite struct SecretRedactorTests {

    @Test func redactsOpenAIStyleKeys() {
        let text = "error talking to sk-abcdefghijklmnopqrstuvwxyz1234567890 server"
        let redacted = SecretRedactor.redact(text)
        #expect(!redacted.contains("sk-abcdefghijklmnopqrstuvwxyz1234567890"))
        #expect(redacted.contains("[REDACTED]"))
    }

    @Test func redactsBearerHeaders() {
        let text = "Authorization: Bearer abcdefghijklmnopqrstuvwxyz1234567890"
        let redacted = SecretRedactor.redact(text)
        #expect(!redacted.contains("abcdefghijklmnopqrstuvwxyz1234567890"))
    }

    @Test func leavesUnrelatedTextUntouched() {
        let text = "response completed in 420ms"
        #expect(SecretRedactor.redact(text) == text)
    }

    @Test func redactsAnthropicKeys() {
        let text = "claude failed for sk-ant-api03-abcdefghijklmnop_QRST-uvwx1234 key"
        let redacted = SecretRedactor.redact(text)
        #expect(!redacted.contains("sk-ant"))
        #expect(!redacted.contains("abcdefghijklmnop"))
        #expect(redacted == "claude failed for [REDACTED] key")
    }

    @Test func redactsShortAnthropicKeys() {
        #expect(SecretRedactor.redact("k=sk-ant-abcdefgh1") == "k=[REDACTED]")
    }

    @Test(arguments: [
        "x-api-key: opaque-value-without-prefix",
        "X-Api-Key=opaque-value-without-prefix",
        "{\"x-api-key\":\"opaque-value-without-prefix\"}",
        "{\"x-api-key\": \"opaque-value-without-prefix\", \"a\": 1}",
        "headers: [\"x-api-key\": \"opaque-value-without-prefix\"]",
    ])
    func redactsXAPIKeyHeaderValues(text: String) {
        let redacted = SecretRedactor.redact(text)
        #expect(!redacted.contains("opaque-value-without-prefix"))
        #expect(redacted.contains("[REDACTED]"))
        #expect(redacted.lowercased().contains("x-api-key"))
    }

    @Test func xAPIKeyWithAnthropicValueIsRedactedOnce() {
        let redacted = SecretRedactor.redact("x-api-key: sk-ant-api03-abcdefghijklmnopqrstuv")
        #expect(redacted == "x-api-key: [REDACTED]")
    }
}
