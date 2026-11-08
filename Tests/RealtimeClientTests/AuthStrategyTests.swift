import Foundation
import Testing
@testable import RealtimeClient

@Suite struct AuthStrategyTests {

    @Test func bearerSetsAuthorizationHeader() {
        var request = URLRequest(url: URL(string: "wss://example.invalid")!)
        AuthStrategy.bearer("token-1").apply(to: &request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
    }

    @Test func customHeaderDoesNotSetAuthorization() {
        var request = URLRequest(url: URL(string: "wss://example.invalid")!)
        AuthStrategy.header(name: "x-api-key", value: "k").apply(to: &request)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
