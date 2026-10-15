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
}
