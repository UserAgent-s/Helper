import Foundation

public actor SessionProfileFreezer {
    private let provider: any ProfileKnowledgeProviding
    private let repository: any SessionRepository
    private let redactedLog: @Sendable (String) -> Void
    private var frozen: [SessionID: ProfileSnapshot] = [:]
    private var observer: Task<Void, Never>?

    public init(provider: any ProfileKnowledgeProviding, repository: any SessionRepository, redactedLog: @escaping @Sendable (String) -> Void = { _ in }) {
        self.provider = provider
        self.repository = repository
        self.redactedLog = redactedLog
    }

    public func observe(_ events: AsyncStream<SessionEvent>) {
        observer?.cancel()
        observer = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    public func stopObserving() {
        observer?.cancel()
        observer = nil
    }

    func handle(_ event: SessionEvent) async {
        switch event {
        case .started(let id, _):
            _ = await snapshot(for: id)
        case .stopped(let id, _), .discarded(let id):
            frozen[id] = nil
        case .bookmarkAdded, .bookmarkRemoved:
            break
        }
    }

    @discardableResult
    public func snapshot(for sessionID: SessionID) async -> ProfileSnapshot? {
        if let existing = frozen[sessionID] { return existing }
        let snapshot: ProfileSnapshot
        do {
            snapshot = try await provider.snapshot()
        } catch {
            redactedLog("profile freeze failed: \(error)")
            return nil
        }
        if let existing = frozen[sessionID] { return existing }
        frozen[sessionID] = snapshot
        do {
            try await repository.setKnowledgeDigest(sessionID: sessionID, digest: snapshot.fingerprint)
        } catch {
            redactedLog("profile digest write failed: \(error)")
        }
        return snapshot
    }

    public var frozenSessionIDs: Set<SessionID> { Set(frozen.keys) }
}
