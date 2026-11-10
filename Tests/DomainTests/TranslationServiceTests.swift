import Foundation
import Testing
@testable import Domain

private actor ScriptedTranslator: TextTranslating {
    nonisolated let providerID: String
    var available: Bool
    var failure: TranslationFailure?
    var delay: Duration
    private(set) var calls: [String] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0

    init(id: String = "fake", available: Bool = true, failure: TranslationFailure? = nil, delay: Duration = .zero) {
        providerID = id
        self.available = available
        self.failure = failure
        self.delay = delay
    }

    func isAvailable() -> Bool { available }

    func translateToRussian(_ text: String) async throws -> String {
        calls.append(text)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if delay > .zero { try? await Task.sleep(for: delay) }
        if let failure { throw failure }
        return "RU(" + text + ")"
    }
}

private func them(_ id: String, _ text: String, language: String? = nil, final: Bool = true) -> TranscriptEvent {
    TranscriptEvent(speaker: .them, itemID: id, text: text, language: language, isFinal: final)
}

private func collect(_ stream: AsyncStream<TranslationEvent>, count: Int) async -> [TranslationEvent] {
    var events: [TranslationEvent] = []
    for await event in stream {
        events.append(event)
        if events.count == count { break }
    }
    return events
}

@Suite struct TranslationPolicyTests {
    @Test func decidesByLanguageAndCyrillicShare() {
        let speakers: Set<Speaker> = [.them]
        #expect(TranslationPolicy.needsTranslation(them("1", "How would you design a payment retry queue?"), speakers: speakers))
        #expect(TranslationPolicy.needsTranslation(them("1", "Расскажите про Kafka", language: "en"), speakers: speakers))
        #expect(!TranslationPolicy.needsTranslation(them("1", "Расскажите, как вы делали ретраи в Kafka"), speakers: speakers))
        #expect(!TranslationPolicy.needsTranslation(them("1", "Ок"), speakers: speakers))
        #expect(!TranslationPolicy.needsTranslation(them("1", "Hello there", final: false), speakers: speakers))
        #expect(!TranslationPolicy.needsTranslation(TranscriptEvent(speaker: .me, itemID: "m", text: "I built it", isFinal: true), speakers: speakers))
        #expect(!TranslationPolicy.needsTranslation(them("1", "  12 345  "), speakers: speakers))
        #expect(TranslationPolicy.needsTranslation(them("1", "Use idempotency key в API"), speakers: speakers))
    }
}

@Suite struct TranslationServiceTests {
    @Test func translatesEnglishOnceAndSkipsRussian() async {
        let translator = ScriptedTranslator()
        let service = TranslationService(primary: translator, fallback: nil)
        let events = service.events(subscriber: "t")
        await service.submit(them("i1", "Tell me about idempotency"))
        await service.submit(them("i1", "Tell me about idempotency"))
        await service.submit(them("i2", "Расскажите про идемпотентность"))
        let received = await collect(events, count: 1)
        #expect(received == [.translated(TranscriptTranslation(speaker: .them, itemID: "i1", sourceText: "Tell me about idempotency", translation: "RU(Tell me about idempotency)", providerID: "fake"))])
        #expect(await translator.calls == ["Tell me about idempotency"])
        #expect(await service.requestCount == 1)
    }

    @Test func atMostTwoConcurrentRequests() async {
        let translator = ScriptedTranslator(delay: .milliseconds(30))
        let service = TranslationService(primary: translator, fallback: nil)
        let events = service.events(subscriber: "t")
        for index in 0..<6 { await service.submit(them("i\(index)", "Question number \(index)")) }
        let received = await collect(events, count: 6)
        #expect(received.count == 6)
        #expect(await translator.maxInFlight == 2)
    }

    @Test func rateLimitLeavesLineUntranslatedWithErrorEvent() async {
        let service = TranslationService(primary: ScriptedTranslator(failure: .rateLimited), fallback: ScriptedTranslator(id: "luna"))
        let events = service.events(subscriber: "t")
        await service.submit(them("i1", "What is your notice period?"))
        #expect(await collect(events, count: 1) == [.failed(speaker: .them, itemID: "i1", failure: .rateLimited)])
    }

    @Test func fallsBackWhenPrimaryUnavailableAndReportsUnavailableWithoutAny() async {
        let luna = ScriptedTranslator(id: "gpt-6-luna")
        let service = TranslationService(primary: ScriptedTranslator(available: false), fallback: luna)
        let events = service.events(subscriber: "t")
        await service.submit(them("i1", "Why are you leaving?"))
        guard case .translated(let result) = await collect(events, count: 1).first else { Issue.record("no translation"); return }
        #expect(result.providerID == "gpt-6-luna")

        let none = TranslationService(primary: ScriptedTranslator(available: false), fallback: nil)
        let noneEvents = none.events(subscriber: "t")
        await none.submit(them("i1", "Why are you leaving?"))
        #expect(await collect(noneEvents, count: 1) == [.failed(speaker: .them, itemID: "i1", failure: .unavailable)])
    }

    @Test func cancelAllOnStopDropsQueueAndInFlightResults() async throws {
        let translator = ScriptedTranslator(delay: .milliseconds(80))
        let service = TranslationService(primary: translator, fallback: nil)
        let events = service.events(subscriber: "t")
        for index in 0..<5 { await service.submit(them("i\(index)", "Long English question \(index)")) }
        #expect(await service.inFlightCount == 2)
        await service.cancelAll()
        #expect(await service.queuedCount == 0)
        await service.submit(them("after", "After stop question"))
        let received = await collect(events, count: 1)
        guard case .translated(let result) = received.first else { Issue.record("expected translation"); return }
        #expect(result.itemID == "after")
    }

    @Test func disabledSettingSkipsEverything() async throws {
        let translator = ScriptedTranslator()
        let service = TranslationService(primary: translator, fallback: nil, isEnabled: { false })
        await service.submit(them("i1", "Hello, can you hear me?"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await translator.calls.isEmpty)
    }
}

@Suite struct SessionRecorderTranslationTests {
    private actor Store: UtteranceTranslationStoring {
        private(set) var writes: [(String, String)] = []
        func setUtteranceTranslation(utteranceID: String, text: String, language: String) { writes.append((utteranceID, text)) }
    }

    @Test func translationIsWrittenToTheRecordedUtteranceInEitherOrder() async throws {
        let repository = InMemorySessionRepository()
        let session = try await repository.create(kind: .assistant, mode: .answers, at: Date())
        let context = FixedSessionContext(session.id)
        let store = Store()
        let recorder = SessionRecorder(repository: repository, sessions: context, translationStore: store)
        await recorder.record(them("i1", "Hello there"))
        await recorder.recordTranslation(TranscriptTranslation(speaker: .them, itemID: "i1", sourceText: "Hello there", translation: "Привет", providerID: "x"))
        await recorder.recordTranslation(TranscriptTranslation(speaker: .them, itemID: "i2", sourceText: "Bye", translation: "Пока", providerID: "x"))
        await recorder.record(them("i2", "Bye now"))
        await recorder.flush()
        let writes = await store.writes
        #expect(writes.map(\.1) == ["Привет", "Пока"])
        let utterances = await repository.utterances[session.id] ?? []
        #expect(Set(writes.map(\.0)) == Set(utterances.map(\.id)))
        #expect(await recorder.translationWriteCount == 2)
    }
}
