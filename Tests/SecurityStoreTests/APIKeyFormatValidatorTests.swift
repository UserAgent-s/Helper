import Domain
import Testing
@testable import SecurityStore

@Suite struct APIKeyFormatValidatorTests {

    @Test func acceptsPlausibleKey() {
        #expect(APIKeyFormatValidator.isPlausibleFormat("sk-abcdefghijklmnopqrstuvwxyz1234567890"))
    }

    @Test func rejectsMissingPrefix() {
        #expect(!APIKeyFormatValidator.isPlausibleFormat("abcdefghijklmnopqrstuvwxyz1234567890"))
    }

    @Test func rejectsTooShort() {
        #expect(!APIKeyFormatValidator.isPlausibleFormat("sk-short"))
    }

    @Test func rejectsWhitespaceAndSymbols() {
        #expect(!APIKeyFormatValidator.isPlausibleFormat("sk-abc def!!!!!!!!!!!!!!!!"))
    }

    @Test func trimsSurroundingWhitespaceBeforeValidating() {
        #expect(APIKeyFormatValidator.isPlausibleFormat("  sk-abcdefghijklmnopqrstuvwxyz1234567890  "))
    }
}

@Suite struct APIKeyProviderMatrixTests {
    private static let openAIKey = "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
    private static let legacyOpenAIKey = "sk-abcdefghijklmnopqrstuvwxyz1234567890"
    private static let anthropicKey = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz_-123"

    @Test(arguments: [
        (openAIKey, SecretProvider.openAI, true),
        (legacyOpenAIKey, .openAI, true),
        (anthropicKey, .openAI, false),
        (openAIKey, .anthropic, false),
        (legacyOpenAIKey, .anthropic, false),
        (anthropicKey, .anthropic, true),
        ("sk-ant-short", .anthropic, false),
        ("sk-ant-", .anthropic, false),
        ("ant-abcdefghijklmnopqrstuvwxyz123456", .anthropic, false),
        ("sk-ant-abc def ghijklmnopqrstuvwxyz", .anthropic, false),
        ("  \(anthropicKey)\n", .anthropic, true),
    ])
    func prefixMatrix(key: String, provider: SecretProvider, expected: Bool) {
        #expect(APIKeyFormatValidator.isPlausibleFormat(key, for: provider) == expected)
    }

    @Test func legacyEntryPointRejectsAnthropicKey() {
        #expect(!APIKeyFormatValidator.isPlausibleFormat(Self.anthropicKey))
    }

    @Test func checkReportsKeyPastedIntoWrongField() {
        #expect(APIKeyFormatValidator.check(Self.anthropicKey, for: .openAI) == .belongsTo(.anthropic))
        #expect(APIKeyFormatValidator.check(Self.openAIKey, for: .anthropic) == .belongsTo(.openAI))
        #expect(APIKeyFormatValidator.check(" \(Self.anthropicKey) ", for: .anthropic) == .valid(Self.anthropicKey))
        #expect(APIKeyFormatValidator.check("garbage", for: .anthropic) == .invalidFormat)
    }
}
