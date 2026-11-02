import Foundation
import Testing
@testable import Domain

@Suite struct UtteranceSegmenterTests {
    @Test func closesUtteranceAfterPauseWithoutWaitingForStop() {
        var segmenter = UtteranceSegmenter()
        var closed: [SpeechUtterance] = []
        for frame in SpeechAudio.utterance(speechMs: 600, pauseMs: 800) {
            closed += segmenter.ingest(frame)
        }
        #expect(closed.count == 1)
        #expect(closed.first?.endReason == .pause)
        #expect(closed.first?.overlapsPrevious == false)
    }

    @Test func ignoresShortNoiseBlips() {
        var segmenter = UtteranceSegmenter()
        var closed: [SpeechUtterance] = []
        closed += segmenter.ingest(SpeechAudio.speech(ms: 100))
        for _ in 0..<10 { closed += segmenter.ingest(SpeechAudio.silence(ms: 100)) }
        #expect(closed.isEmpty)
    }

    @Test func longSpeechIsSplitWithOverlapSoNothingWaitsForTheEnd() {
        var segmenter = UtteranceSegmenter(configuration: UtteranceSegmenterConfiguration(maximumUtteranceMs: 2_000, overlapMs: 500))
        var closed: [SpeechUtterance] = []
        for _ in 0..<45 { closed += segmenter.ingest(SpeechAudio.speech(ms: 100)) }
        #expect(closed.count == 2)
        #expect(closed.allSatisfy { $0.endReason == .maxDuration })
        #expect(closed[0].overlapsPrevious == false)
        #expect(closed[1].overlapsPrevious == true)
        #expect(segmenter.bufferedDurationMs <= 2_000)
    }

    @Test func forceCloseFlushesPendingSpeechForManualTrigger() {
        var segmenter = UtteranceSegmenter()
        for _ in 0..<5 { _ = segmenter.ingest(SpeechAudio.speech(ms: 100)) }
        let forced = segmenter.forceClose()
        #expect(forced?.endReason == .forced)
        #expect(segmenter.forceClose() == nil)
    }

    @Test func preRollStaysBoundedDuringLongSilence() {
        var segmenter = UtteranceSegmenter()
        for _ in 0..<600 { _ = segmenter.ingest(SpeechAudio.silence(ms: 100)) }
        #expect(segmenter.bufferedDurationMs <= UtteranceSegmenterConfiguration.default.preRollMs + 100)
    }
}

@Suite struct SessionTranscriptContextTests {
    @Test func removesDuplicatedWordsAtOverlappingBoundary() {
        var context = SessionTranscriptContext()
        context.append("Расскажите, как вы проектировали очередь", overlapsPrevious: false)
        context.append("проектировали очередь на RabbitMQ с повторами?", overlapsPrevious: true)
        #expect(context.text == "Расскажите, как вы проектировали очередь на RabbitMQ с повторами?")
        #expect(context.duplicateFragmentCount == 1)
    }

    @Test func dropsImmediateExactDuplicateFragment() {
        var context = SessionTranscriptContext()
        let now = Date()
        context.append("Что такое идемпотентность?", overlapsPrevious: false, at: now)
        let duplicate = context.append("что такое идемпотентность", overlapsPrevious: false, at: now.addingTimeInterval(1))
        #expect(duplicate == nil)
        #expect(context.fragments.count == 1)
    }

    @Test func keepsLegitimateRepetitionWithoutOverlapFlagWhenShort() {
        var context = SessionTranscriptContext()
        context.append("Хорошо.", overlapsPrevious: false)
        context.append("Хорошо, а как насчёт индексов?", overlapsPrevious: false)
        #expect(context.text == "Хорошо. Хорошо, а как насчёт индексов?")
    }

    @Test func filtersKnownWhisperSilenceHallucinations() {
        var context = SessionTranscriptContext()
        #expect(context.append("Продолжение следует...", overlapsPrevious: false) == nil)
        #expect(context.isEmpty)
    }

    @Test func boundsMemoryByDroppingOldestFragments() {
        var context = SessionTranscriptContext(maxCharacters: 60)
        for index in 0..<10 {
            context.append("фрагмент номер \(index) с текстом", overlapsPrevious: false)
        }
        #expect(context.text.count <= 60)
        #expect(context.droppedFragmentCount > 0)
        #expect(context.text.contains("номер 9"))
    }

    @Test func consumingAnsweredFragmentsKeepsSpeechThatArrivedDuringStreaming() {
        var context = SessionTranscriptContext()
        let first = context.append("Как работает MVCC?", overlapsPrevious: false)
        context.append("И ещё про vacuum", overlapsPrevious: false)
        context.consumeThrough(sequence: first!.sequence)
        #expect(context.text == "И ещё про vacuum")
    }

    @Test func priorExchangesAreBounded() {
        var context = SessionTranscriptContext(maxPriorExchanges: 2)
        for index in 0..<5 {
            context.recordExchange(question: "q\(index)", answer: "a\(index)")
        }
        #expect(context.priorExchanges.map(\.question) == ["q3", "q4"])
        context.clearAll()
        #expect(context.priorExchanges.isEmpty)
    }
}

@Suite struct HeuristicQuestionReadinessDetectorTests {
    let detector = HeuristicQuestionReadinessDetector()

    @Test func detectsRussianAndEnglishQuestionsAfterPause() {
        #expect(detector.isReadyToAnswer(accumulatedTranscript: "Как бы вы спроектировали rate limiter", lastFragment: "Как бы вы спроектировали rate limiter", endedByPause: true))
        #expect(detector.isReadyToAnswer(accumulatedTranscript: "Tell me about a time you handled an outage", lastFragment: "Tell me about a time you handled an outage", endedByPause: true))
        #expect(detector.isReadyToAnswer(accumulatedTranscript: "Вы использовали Kafka в продакшене?", lastFragment: "Вы использовали Kafka в продакшене?", endedByPause: true))
    }

    @Test func waitsWhileSpeakerIsStillTalking() {
        #expect(!detector.isReadyToAnswer(accumulatedTranscript: "Как бы вы спроектировали", lastFragment: "Как бы вы спроектировали", endedByPause: false))
    }

    @Test func taskExplanationWithoutQuestionIsNotReady() {
        #expect(!detector.isReadyToAnswer(accumulatedTranscript: "У нас есть сервис заказов на Laravel и очередь в SQS.", lastFragment: "У нас есть сервис заказов на Laravel и очередь в SQS.", endedByPause: true))
    }
}

@Suite struct UsageAndCostTests {
    @Test func unknownUsageIsNotZeroCost() async {
        let telemetry = SessionTelemetry()
        await telemetry.begin(configuration: .claudeTest(), spendPolicy: .none)
        await telemetry.recordResponseWithoutUsage()
        let snapshot = await telemetry.snapshot()
        #expect(snapshot.cost == nil)
        #expect(!snapshot.usageKnown)
    }

    @Test func partialUsageMakesTotalCostUnknownRatherThanUnderstated() async {
        let telemetry = SessionTelemetry()
        await telemetry.begin(configuration: .claudeTest(), spendPolicy: .none)
        await telemetry.recordUsage(ProviderUsage(inputTokens: 1000, outputTokens: 100))
        #expect(await telemetry.snapshot().cost != nil)
        await telemetry.recordResponseWithoutUsage()
        #expect(await telemetry.snapshot().cost == nil)
    }

    @Test func anthropicCostIncludesCacheReadAndWriteAndCarriesSource() throws {
        let pricing = try #require(AnswerModelCatalog.descriptor(provider: .anthropicClaude, modelID: "claude-opus-5-5")?.pricing)
        let usage = ProviderUsage(inputTokens: 1_000_000, cachedInputTokens: 1_000_000, cacheCreationInputTokens: 1_000_000, outputTokens: 1_000_000)
        let cost = try #require(UsageCostCalculator.estimate(usage, provider: .anthropicClaude, pricing: pricing))
        let expected: Double = 4 + 0.20 + 5 + 20
        #expect(abs(cost.approximateUSD - expected) < 0.0001)
        #expect(!cost.pricing.sourceURL.isEmpty)
        #expect(!cost.pricing.verifiedOn.isEmpty)
    }

    @Test func openAICostSeparatesAudioTextAndCachedTokens() throws {
        let pricing = try #require(AnswerModelCatalog.descriptor(provider: .openAIRealtime, modelID: "gpt-realtime-2.1")?.pricing)
        let usage = ProviderUsage(inputTextTokens: 1_000_000, inputAudioTokens: 2_000_000, cachedTextTokens: 500_000, cachedAudioTokens: 1_000_000, outputTextTokens: 100_000)
        let cost = try #require(UsageCostCalculator.estimate(usage, provider: .openAIRealtime, pricing: pricing))
        let textInput: Double = 0.5 * 4
        let audioInput: Double = 1 * 32
        let cachedText: Double = 0.5 * 0.40
        let cachedAudio: Double = 1 * 0.40
        let output: Double = 0.1 * 24
        let expected = textInput + audioInput + cachedText + cachedAudio + output
        #expect(abs(cost.approximateUSD - expected) < 0.0001)
    }

    @Test func openAIUsageWithoutModalityBreakdownIsUnknown() throws {
        let pricing = try #require(AnswerModelCatalog.descriptor(provider: .openAIRealtime, modelID: "gpt-realtime-2.1")?.pricing)
        #expect(UsageCostCalculator.estimate(ProviderUsage(inputTokens: 10, outputTokens: 10), provider: .openAIRealtime, pricing: pricing) == nil)
    }

    @Test func customModelWithoutTariffHasUnknownCost() async {
        let telemetry = SessionTelemetry()
        let configuration = AnswerSessionConfiguration.claudeTest(modelID: "claude-unlisted-1", isCustom: true)
        await telemetry.begin(configuration: configuration, spendPolicy: SpendPolicy(limitUSD: 1, mode: .stopSession))
        await telemetry.recordUsage(ProviderUsage(inputTokens: 10, outputTokens: 10))
        let snapshot = await telemetry.snapshot()
        #expect(snapshot.cost == nil)
        #expect(snapshot.spendState == .unenforceableCostUnknown)
    }

    @Test func spendLimitDistinguishesWarningFromEnforcedStop() async {
        let warn = SessionTelemetry()
        await warn.begin(configuration: .claudeTest(), spendPolicy: SpendPolicy(limitUSD: 0.000001, mode: .warnOnly))
        let warnStop = await warn.recordUsage(ProviderUsage(inputTokens: 1000, outputTokens: 1000))
        #expect(!warnStop)
        #expect(await warn.snapshot().spendState == .limitReachedWarning)

        let stop = SessionTelemetry()
        await stop.begin(configuration: .claudeTest(), spendPolicy: SpendPolicy(limitUSD: 0.000001, mode: .stopSession))
        let shouldStop = await stop.recordUsage(ProviderUsage(inputTokens: 1000, outputTokens: 1000))
        #expect(shouldStop)
        #expect(await stop.snapshot().spendState == .limitReachedStopped)
    }

    @Test func servedFallbackModelPricesByTheModelThatActuallyAnswered() async {
        let telemetry = SessionTelemetry()
        await telemetry.begin(configuration: .claudeTest(), spendPolicy: .none)
        await telemetry.setServedModel("claude-opus-4-8")
        await telemetry.recordUsage(ProviderUsage(inputTokens: 10, outputTokens: 10))
        #expect(await telemetry.snapshot().cost == nil)
    }
}

@Suite struct AnswerProviderErrorMappingTests {
    @Test func mapsAnthropicHTTPStatuses() {
        #expect(AnswerProviderError.fromAnthropicHTTP(status: 401, errorType: "authentication_error", message: nil, retryAfter: nil) == .authentication)
        #expect(AnswerProviderError.fromAnthropicHTTP(status: 402, errorType: "billing_error", message: nil, retryAfter: nil) == .billing)
        #expect(AnswerProviderError.fromAnthropicHTTP(status: 429, errorType: "rate_limit_error", message: nil, retryAfter: 12) == .rateLimited(retryAfterSeconds: 12))
        #expect(AnswerProviderError.fromAnthropicHTTP(status: 529, errorType: "overloaded_error", message: nil, retryAfter: nil) == .overloaded)
        #expect(AnswerProviderError.fromAnthropicHTTP(status: 404, errorType: "not_found_error", message: "model: x", retryAfter: nil) == .modelNotFound("model: x"))
    }

    @Test func sessionEndingVersusRetryableClassification() {
        #expect(AnswerProviderError.authentication.endsSession)
        #expect(AnswerProviderError.billing.endsSession)
        #expect(!AnswerProviderError.rateLimited(retryAfterSeconds: nil).endsSession)
        #expect(AnswerProviderError.network("x").isRetryableLater)
        #expect(!AnswerProviderError.network("x").endsSession)
    }

    @Test func mapsOpenAIRealtimeCodes() {
        #expect(AnswerProviderError.fromOpenAIRealtimeCode("invalid_api_key") == .authentication)
        #expect(AnswerProviderError.fromOpenAIRealtimeCode("insufficient_quota") == .billing)
        #expect(AnswerProviderError.fromOpenAIRealtimeCode("rate_limit_exceeded") == .rateLimited(retryAfterSeconds: nil))
    }
}

@Suite struct ModelIDValidatorTests {
    @Test func acceptsCatalogStyleIdentifiers() {
        #expect(ModelIDValidator.isPlausible("claude-opus-5-5"))
        #expect(ModelIDValidator.isPlausible("gpt-realtime-2.1-mini"))
    }

    @Test func rejectsWhitespaceInjectionAndGarbage() {
        #expect(!ModelIDValidator.isPlausible(" claude"))
        #expect(!ModelIDValidator.isPlausible("a b"))
        #expect(!ModelIDValidator.isPlausible("gpt&model=x"))
        #expect(!ModelIDValidator.isPlausible("x"))
        #expect(!ModelIDValidator.isPlausible(String(repeating: "a", count: 101)))
    }
}

extension AnswerSessionConfiguration {
    static func claudeTest(modelID: String = "claude-opus-5-5", isCustom: Bool = false) -> AnswerSessionConfiguration {
        AnswerSessionConfiguration(
            selection: AnswerModelSelection(provider: .anthropicClaude, modelID: modelID, isCustom: isCustom),
            triggerMode: .automatic,
            answerLength: .standard,
            profileFingerprint: ""
        )
    }

    static func openAITest() -> AnswerSessionConfiguration {
        AnswerSessionConfiguration(
            selection: AnswerModelSelection(provider: .openAIRealtime, modelID: "gpt-realtime-2.1", isCustom: false),
            triggerMode: .automatic,
            answerLength: .standard,
            profileFingerprint: ""
        )
    }
}
