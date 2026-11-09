import Foundation

public actor SessionRecorder {
    private let repository: any SessionRepository
    private let sessions: any SessionContextProviding
    private let now: @Sendable () -> Date
    private let itemRetention: Int

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
        itemRetention: Int = 512
    ) {
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
        let utterance = SessionUtterance(
            id: "utt_\(UUID().uuidString)",
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
    }

    private func noteWrite(succeeded: Bool) {
        if succeeded { writtenCount += 1 } else { failedWriteCount += 1 }
    }

    private func remember(_ key: String) {
        recordedItems.insert(key)
        recordedOrder.append(key)
        while recordedOrder.count > itemRetention {
            recordedItems.remove(recordedOrder.removeFirst())
        }
    }
}
