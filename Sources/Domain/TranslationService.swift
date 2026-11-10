import Foundation

public enum TranslationFailure: Error, Sendable, Equatable {
    case unavailable
    case rateLimited
    case failed(String)

    public var code: String {
        switch self {
        case .unavailable: "translation_unavailable"
        case .rateLimited: "translation_rate_limited"
        case .failed: "translation_failed"
        }
    }
}

public protocol TextTranslating: Sendable {
    var providerID: String { get }
    func isAvailable() async -> Bool
    func translateToRussian(_ text: String) async throws -> String
}

public struct TranscriptTranslation: Sendable, Equatable {
    public let speaker: Speaker
    public let itemID: String
    public let sourceText: String
    public let translation: String
    public let language: String
    public let providerID: String

    public init(speaker: Speaker, itemID: String, sourceText: String, translation: String, language: String = "ru", providerID: String) {
        self.speaker = speaker
        self.itemID = itemID
        self.sourceText = sourceText
        self.translation = translation
        self.language = language
        self.providerID = providerID
    }
}

public enum TranslationEvent: Sendable, Equatable {
    case translated(TranscriptTranslation)
    case failed(speaker: Speaker, itemID: String, failure: TranslationFailure)
}

public enum TranslationPolicy {
    public static let cyrillicThreshold = 0.2

    public static func needsTranslation(_ event: TranscriptEvent, speakers: Set<Speaker>) -> Bool {
        guard event.isFinal, speakers.contains(event.speaker) else { return false }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        var letters = 0
        var cyrillic = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            if (0x0400...0x04FF).contains(scalar.value) { cyrillic += 1 }
        }
        guard letters >= 2 else { return false }
        if let language = event.language?.lowercased(), language.hasPrefix("en") { return true }
        return Double(cyrillic) / Double(letters) < cyrillicThreshold
    }
}

public actor TranslationService {
    public static let maxConcurrent = 2
    public static let maxQueued = 16

    private let primary: (any TextTranslating)?
    private let fallback: (any TextTranslating)?
    private let isEnabled: @Sendable () -> Bool
    private let speakers: Set<Speaker>
    private let redactedLog: @Sendable (String) -> Void
    private let broadcaster = AsyncBroadcaster<TranslationEvent>()

    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private var queue: [TranscriptEvent] = []
    private var running: [String: Task<Void, Never>] = [:]
    private var feed: Task<Void, Never>?
    private var generation = 0
    public private(set) var requestCount = 0
    public private(set) var droppedCount = 0

    public init(
        primary: (any TextTranslating)?,
        fallback: (any TextTranslating)?,
        isEnabled: @escaping @Sendable () -> Bool = { true },
        speakers: Set<Speaker> = [.them],
        redactedLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.primary = primary
        self.fallback = fallback
        self.isEnabled = isEnabled
        self.speakers = speakers
        self.redactedLog = redactedLog
    }

    nonisolated public func events(subscriber: String) -> AsyncStream<TranslationEvent> {
        broadcaster.subscribe(subscriber)
    }

    public func attach(_ transcripts: AsyncStream<TranscriptEvent>) {
        feed?.cancel()
        feed = Task { [weak self] in
            for await event in transcripts {
                if Task.isCancelled { break }
                await self?.submit(event)
            }
        }
    }

    public func submit(_ event: TranscriptEvent) {
        guard isEnabled(), TranslationPolicy.needsTranslation(event, speakers: speakers) else { return }
        let key = "\(event.speaker.rawValue):\(event.itemID)"
        guard !seen.contains(key) else { return }
        remember(key)
        queue.append(event)
        if queue.count > Self.maxQueued {
            queue.removeFirst(queue.count - Self.maxQueued)
            droppedCount += 1
        }
        pump()
    }

    public func cancelAll() {
        generation += 1
        queue.removeAll()
        running.values.forEach { $0.cancel() }
        running.removeAll()
    }

    public var inFlightCount: Int { running.count }
    public var queuedCount: Int { queue.count }

    private func pump() {
        while running.count < Self.maxConcurrent, !queue.isEmpty {
            let event = queue.removeFirst()
            let key = "\(event.speaker.rawValue):\(event.itemID)"
            let generation = self.generation
            requestCount += 1
            running[key] = Task { [weak self] in
                let result = await self?.translate(event)
                await self?.complete(key: key, event: event, result: result, generation: generation)
            }
        }
    }

    private func translate(_ event: TranscriptEvent) async -> Result<(String, String), TranslationFailure> {
        var translator: (any TextTranslating)?
        if let primary, await primary.isAvailable() {
            translator = primary
        } else if let fallback, await fallback.isAvailable() {
            translator = fallback
        }
        guard let translator else { return .failure(.unavailable) }
        do {
            let text = try await translator.translateToRussian(event.text)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.failed("empty")) }
            return .success((trimmed, translator.providerID))
        } catch let failure as TranslationFailure {
            return .failure(failure)
        } catch {
            return .failure(.failed(String(describing: type(of: error))))
        }
    }

    private func complete(key: String, event: TranscriptEvent, result: Result<(String, String), TranslationFailure>?, generation: Int) {
        running[key] = nil
        defer { pump() }
        guard generation == self.generation, let result, !Task.isCancelled else { return }
        switch result {
        case .success(let (translation, provider)):
            broadcaster.yield(.translated(TranscriptTranslation(speaker: event.speaker, itemID: event.itemID, sourceText: event.text, translation: translation, providerID: provider)))
        case .failure(let failure):
            redactedLog("translation failed: \(failure.code)")
            broadcaster.yield(.failed(speaker: event.speaker, itemID: event.itemID, failure: failure))
        }
    }

    private func remember(_ key: String) {
        seen.insert(key)
        seenOrder.append(key)
        if seenOrder.count > 1_024 {
            let excess = seenOrder.count - 1_024
            for old in seenOrder.prefix(excess) { seen.remove(old) }
            seenOrder.removeFirst(excess)
        }
    }
}

public protocol UtteranceTranslationStoring: Sendable {
    func setUtteranceTranslation(utteranceID: String, text: String, language: String) async throws
}
