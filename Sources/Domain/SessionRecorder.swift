import Foundation

public actor SessionRecorder {
    private let repository: any SessionRepository
    private let sessions: any SessionContextProviding
    private let now: @Sendable () -> Date
    private let itemRetention: Int
    private let translationStore: (any UtteranceTranslationStoring)?
    private var utteranceIDs: [String: String] = [:]
    private var pendingTranslations: [String: TranscriptTranslation] = [:]
    public private(set) var translationWriteCount = 0

    private var feeds: [Task<Void, Never>] = []
    private var writeTail: Task<Void, Never>?
    private var recordedItems: Set<String> = []
    private var recordedOrder: [String] = []
    public private(set) var writtenCount = 0
    public private(set) var droppedWithoutSessionCount = 0
    public private(set) var failedWriteCount = 0

    public init(
        repository: any SessionRepository,
        sessions: any SessionContextProviding,
        now: @escaping @Sendable () -> Date = { Date() },
        itemRetention: Int = 512,
        translationStore: (any UtteranceTranslationStoring)? = nil
    ) {
        self.translationStore = translationStore
        self.repository = repository
        self.sessions = sessions
        self.now = now
        self.itemRetention = itemRetention
    }

    public func attach(_ events: AsyncStream<TranscriptEvent>) {
        feeds.append(Task { [weak self] in
            for await event in events {
                if Task.isCancelled { break }
                await self?.record(event)
            }
        })
    }

    public func attachTranslations(_ events: AsyncStream<TranslationEvent>) {
        feeds.append(Task { [weak self] in
            for await event in events {
                if Task.isCancelled { break }
                if case .translated(let translation) = event {
                    await self?.recordTranslation(translation)
                }
            }
        })
    }

    public func recordTranslation(_ translation: TranscriptTranslation) {
        let key = "\(translation.speaker.rawValue):\(translation.itemID)"
        guard let utteranceID = utteranceIDs[key] else {
            if recordedItems.contains(key) || pendingTranslations.count < itemRetention {
                pendingTranslations[key] = translation
            }
            return
        }
        writeTranslation(utteranceID: utteranceID, translation)
    }

    private func writeTranslation(utteranceID: String, _ translation: TranscriptTranslation) {
        guard let translationStore else { return }
        let previous = writeTail
        writeTail = Task { [weak self] in
            await previous?.value
            do {
                try await translationStore.setUtteranceTranslation(utteranceID: utteranceID, text: translation.translation, language: translation.language)
                await self?.noteTranslationWrite()
            } catch {
                await self?.noteWrite(succeeded: false)
            }
        }
    }

    private func noteTranslationWrite() {
        translationWriteCount += 1
    }

    public func detach() {
        feeds.forEach { $0.cancel() }
        feeds.removeAll()
    }

    public func flush() async {
        await writeTail?.value
    }

    public func record(_ event: TranscriptEvent) async {
        guard event.isFinal else { return }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let key = "\(event.speaker.rawValue):\(event.itemID)"
        guard !recordedItems.contains(key) else { return }
        remember(key)
        let capturedAt = now()
        guard let sessionID = await sessions.activeSessionID else {
            droppedWithoutSessionCount += 1
            return
        }
        let utteranceID = "utt_\(UUID().uuidString)"
        let utterance = SessionUtterance(
            id: utteranceID,
            speaker: event.speaker,
            origin: event.speaker == .me ? .meChannel : .realtimeInput,
            text: text,
            capturedAt: capturedAt,
            language: event.language
        )
        let repository = self.repository
        let previous = writeTail
        writeTail = Task { [weak self] in
            await previous?.value
            do {
                try await repository.appendUtterance(utterance, sessionID: sessionID)
                await self?.noteWrite(succeeded: true)
            } catch {
                await self?.noteWrite(succeeded: false)
            }
        }
        utteranceIDs[key] = utteranceID
        if let pending = pendingTranslations.removeValue(forKey: key) {
            writeTranslation(utteranceID: utteranceID, pending)
        }
    }

    private func noteWrite(succeeded: Bool) {
        if succeeded { writtenCount += 1 } else { failedWriteCount += 1 }
    }

    private func remember(_ key: String) {
        recordedItems.insert(key)
        recordedOrder.append(key)
        while recordedOrder.count > itemRetention {
            let old = recordedOrder.removeFirst()
            recordedItems.remove(old)
            utteranceIDs[old] = nil
            pendingTranslations[old] = nil
        }
    }
}
