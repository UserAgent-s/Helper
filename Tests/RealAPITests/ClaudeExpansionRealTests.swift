import ClaudeClient
import Domain
import Foundation
import ProfileKnowledge
import Testing

enum ClaudeRealEnvironment {
    static var apiKey: String? {
        let value = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        return value?.isEmpty == false ? value : nil
    }

    static var isEnabled: Bool { RealAPIEnvironment.isEnabled && apiKey != nil }

    static var rounds: Int {
        guard let raw = ProcessInfo.processInfo.environment["CLAUDE_LATENCY_ROUNDS"], let parsed = Int(raw), parsed > 0 else { return 5 }
        return min(parsed, 10)
    }

    static func profile() async throws -> ProfileSnapshot {
        if let path = ProcessInfo.processInfo.environment["UA057_PROFILE_DIR"], !path.isEmpty {
            let config = ProfileFolderConfiguration(folder: URL(fileURLWithPath: path), selectedPaths: nil)
            return try await MarkdownFolderProfileProvider(configuration: { config }, legacyText: { "" }).snapshot()
        }
        let paragraph = "Senior backend engineer. PHP 8.3, Symfony, Go, PostgreSQL, Kafka, Redis, AWS Lambda, AppSync. Built a payment gateway with idempotent retries, reconciliation and PSP routing; led a team of five; cut p95 latency from 900 ms to 180 ms. "
        let text = (1...40).map { "## Project \($0)\n" + paragraph }.joined(separator: "\n")
        return ProfileSnapshot(source: .markdownFolder(path: "synthetic"), documents: [ProfileDocument(relativePath: "02_CURRENT_PROFILE.md", text: text)], fingerprint: "synthetic", estimatedTokens: ProfileTokenEstimator.estimate(text), sizeStatus: .ok)
    }

    static func client() -> ClaudeMessagesClient {
        let key = apiKey
        return ClaudeMessagesClient(apiKey: { key })
    }

    static func request(_ model: ClaudeModel, profile: ProfileSnapshot, question: String, maxTokens: Int = 400) -> ClaudeMessagesRequest {
        let turn = ClaudePromptBuilder.initialTurn(ExpansionRequest(source: .freeText(question), format: .short, language: .ru))
        return ClaudeMessagesRequest(model: model, maxTokens: maxTokens, effort: .low, system: ClaudePromptBuilder.system(profile: profile), messages: [turn])
    }

    static func log(_ line: String) {
        print("VERIFY_REAL claude " + line)
    }
}

struct ClaudeRun {
    let ttftMs: Int?
    let usage: ClaudeUsage?
    let model: String
    let outcome: String
}

func runClaude(_ client: ClaudeMessagesClient, _ request: ClaudeMessagesRequest) async -> ClaudeRun {
    let clock = ContinuousClock()
    let start = clock.now
    var ttft: Int?
    var usage: ClaudeUsage?
    var model = request.model.rawValue
    var outcome = "incomplete"
    for await event in client.stream(request) {
        switch event {
        case .started(_, let served, _): model = served
        case .textDelta:
            if ttft == nil {
                let elapsed = clock.now - start
                ttft = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            }
        case .fallback(_, let to): model = to ?? model
        case .completed(let completion): usage = completion.usage; outcome = "completed"
        case .truncated(let completion): usage = completion.usage; outcome = "truncated"
        case .refused(let refusal): usage = refusal.usage; outcome = "refused_\(refusal.category ?? "null")"
        case .failed(let failure): outcome = "failed_\(failure)"
        }
    }
    return ClaudeRun(ttftMs: ttft, usage: usage, model: model, outcome: outcome)
}

@Suite(.enabled(if: ClaudeRealEnvironment.isEnabled), .serialized)
struct ClaudeExpansionRealTests {
    @Test func countTokensOfProfileVersusEstimate() async throws {
        let profile = try await ClaudeRealEnvironment.profile()
        let client = ClaudeRealEnvironment.client()
        for model in [ClaudeModel.sonnet, .opus] {
            let request = ClaudeRealEnvironment.request(model, profile: profile, question: "ok")
            let tokens = try await client.countTokens(request).get()
            ClaudeRealEnvironment.log("count_tokens model=\(model.rawValue) system+question=\(tokens) estimate=\(profile.estimatedTokens) bytes=\(profile.totalBytes) docs=\(profile.documents.count)")
            #expect(tokens > ClaudeModelCatalog.info(model).minimumCacheableTokens)
        }
    }

    @Test func prewarmThenEveryExpansionReadsTheCache() async throws {
        let profile = try await ClaudeRealEnvironment.profile()
        let client = ClaudeRealEnvironment.client()
        let base = ClaudeRealEnvironment.request(.sonnet, profile: profile, question: "Кратко: чем я занимался последние два года?")
        let warm = try await client.prewarm(base).get()
        ClaudeRealEnvironment.log("prewarm write=\(warm.usage.cacheCreationInputTokens) write1h=\(warm.usage.cacheCreation1hTokens ?? -1) read=\(warm.usage.cacheReadInputTokens) stop=\(warm.stopReason) cost=\(String(format: "%.4f", ClaudeCostEstimator.estimate(warm.usage, model: .sonnet).total))")
        #expect(warm.usage.cacheCreationInputTokens + warm.usage.cacheReadInputTokens > 0)
        #expect(warm.usage.outputTokens == 0)
        for (index, question) in ["Кратко: чем я занимался последние два года?", "Какой у меня опыт с Kafka?"].enumerated() {
            let run = await runClaude(client, ClaudeRealEnvironment.request(.sonnet, profile: profile, question: question))
            let usage = try #require(run.usage)
            ClaudeRealEnvironment.log("expansion#\(index + 1) model=\(run.model) outcome=\(run.outcome) ttft_ms=\(run.ttftMs ?? -1) read=\(usage.cacheReadInputTokens) write=\(usage.cacheCreationInputTokens) input=\(usage.inputTokens) output=\(usage.outputTokens) cost=\(String(format: "%.4f", ClaudeCostEstimator.estimate(usage, model: .sonnet).total))")
            #expect(run.outcome == "completed")
            #expect(usage.cacheReadInputTokens > 0)
        }
    }

    @Test(arguments: [ClaudeModel.sonnet, .opus])
    func ttftPercentiles(model: ClaudeModel) async throws {
        let profile = try await ClaudeRealEnvironment.profile()
        let client = ClaudeRealEnvironment.client()
        _ = await client.prewarm(ClaudeRealEnvironment.request(model, profile: profile, question: "warmup"))
        var ttfts: [Int] = []
        var totalCost = 0.0
        var reads = 0
        let questions = ["Расскажи про мой самый сложный проект", "Как я обеспечивал идемпотентность платежей?", "Какие у меня слабые места по опыту?", "Почему я ухожу с текущей работы?", "Как бы я спроектировал очередь ретраев?"]
        for round in 0..<ClaudeRealEnvironment.rounds {
            let run = await runClaude(client, ClaudeRealEnvironment.request(model, profile: profile, question: questions[round % questions.count]))
            if let ttft = run.ttftMs { ttfts.append(ttft) }
            if let usage = run.usage {
                totalCost += ClaudeCostEstimator.estimate(usage, model: model).total
                if usage.cacheReadInputTokens > 0 { reads += 1 }
            }
            #expect(run.outcome == "completed" || run.outcome == "truncated")
        }
        let summary = LatencySummary(label: "ttft \(model.rawValue)", valuesMs: ttfts)
        ClaudeRealEnvironment.log("ttft model=\(model.rawValue) rounds=\(ttfts.count) p50_ms=\(summary.p50) p95_ms=\(summary.p95) cache_hits=\(reads) total_cost=\(String(format: "%.4f", totalCost))")
        #expect(ttfts.count == ClaudeRealEnvironment.rounds)
        #expect(reads == ClaudeRealEnvironment.rounds)
    }
}
