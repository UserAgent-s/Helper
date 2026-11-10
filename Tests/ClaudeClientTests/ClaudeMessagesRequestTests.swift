import Foundation
import Testing
@testable import ClaudeClient

@Suite struct ClaudeMessagesRequestTests {
    private func sample(model: ClaudeModel = .sonnet) -> ClaudeMessagesRequest {
        ClaudeMessagesRequest(
            model: model,
            maxTokens: 2_048,
            effort: .low,
            system: [
                ClaudeSystemBlock(text: "Ты отвечаешь от первого лица владельца."),
                ClaudeSystemBlock(text: "<profile>\nSenior PHP\n</profile>", cacheTTL: .oneHour),
            ],
            messages: [.user("Формат: кратко. Язык: ru.", "Вопрос: расскажи про RedCore")]
        )
    }

    @Test func goldenBody() throws {
        let json = String(decoding: try sample().body(), as: UTF8.self)
        let expected = #"{"fallbacks":"default","max_tokens":2048,"messages":[{"content":[{"text":"Формат: кратко. Язык: ru.","type":"text"},{"text":"Вопрос: расскажи про RedCore","type":"text"}],"role":"user"}],"model":"claude-sonnet-5-5","output_config":{"effort":"low"},"stream":true,"system":[{"text":"Ты отвечаешь от первого лица владельца.","type":"text"},{"cache_control":{"ttl":"1h","type":"ephemeral"},"text":"<profile>\nSenior PHP\n</profile>","type":"text"}],"thinking":{"type":"adaptive"}}"#
        #expect(json == expected)
    }

    @Test func cachePointIsOnProfileBlockOnlyAndNoSamplingParameters() throws {
        let object = try #require(JSONSerialization.jsonObject(with: sample().body()) as? [String: Any])
        let system = try #require(object["system"] as? [[String: Any]])
        #expect(system[0]["cache_control"] == nil)
        let cache = try #require(system[1]["cache_control"] as? [String: String])
        #expect(cache == ["type": "ephemeral", "ttl": "1h"])
        #expect((system[1]["text"] as? String)?.hasPrefix("<profile>") == true)
        for key in ["temperature", "top_p", "top_k", "budget_tokens"] {
            #expect(object[key] == nil)
        }
        #expect((object["thinking"] as? [String: String]) == ["type": "adaptive"])
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(!String(describing: messages).contains("cache_control"))
    }

    @Test func headers() throws {
        let request = try sample().urlRequest(apiKey: "sk-ant-api03-test")
        #expect(request.httpMethod == "POST")
        #expect(request.url == URL(string: "https://api.anthropic.com/v1/messages"))
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-api03-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func haikuHasNoServerFallback() throws {
        let request = try sample(model: .haiku).urlRequest(apiKey: "k")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        let object = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(object["fallbacks"] == nil)
        var optedOut = sample()
        optedOut.serverFallback = false
        #expect(try optedOut.urlRequest(apiKey: "k").value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test func bodyIsByteStableAcrossBuilds() throws {
        #expect(try sample().body() == sample().body())
    }

    @Test func prewarmShapeOmitsStream() throws {
        var request = sample()
        request.stream = false
        request.maxTokens = 0
        let object = try #require(JSONSerialization.jsonObject(with: request.body()) as? [String: Any])
        #expect(object["stream"] == nil)
        #expect(object["max_tokens"] as? Int == 0)
        request.stream = true
        #expect(throws: ClaudeRequestError.prewarmMustNotStream) { try request.body() }
    }

    @Test func validationRejectsBadShapes() {
        var request = sample()
        request.messages = [.assistant("hi")]
        #expect(throws: ClaudeRequestError.firstMessageMustBeUser) { try request.body() }
        request.messages = [.user("a"), .assistant("b")]
        #expect(throws: ClaudeRequestError.lastMessageMustBeUser) { try request.body() }
        request.messages = [.user("a"), .user("b")]
        #expect(throws: ClaudeRequestError.rolesMustAlternate) { try request.body() }
        request.messages = [.user("  ")]
        #expect(throws: ClaudeRequestError.emptyText) { try request.body() }
        request = sample()
        request.system = [ClaudeSystemBlock(text: "a", cacheTTL: .fiveMinutes), ClaudeSystemBlock(text: "b", cacheTTL: .oneHour)]
        #expect(throws: ClaudeRequestError.cacheTTLOrder) { try request.body() }
        request = sample()
        request.maxTokens = 200_000
        #expect(throws: ClaudeRequestError.invalidMaxTokens(200_000)) { try request.body() }
    }
}
