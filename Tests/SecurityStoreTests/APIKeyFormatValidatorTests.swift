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
