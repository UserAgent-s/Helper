import Foundation
import Testing
@testable import Domain

private actor FakeProfile: ProfileKnowledgeProviding {
    var text = "v1"
    var failing = false
    private(set) var snapshotCalls = 0

    func set(_ text: String) { self.text = text }
    func setFailing(_ value: Bool) { failing = value }

    func snapshot() throws -> ProfileSnapshot {
        snapshotCalls += 1
        if failing { throw ProfileKnowledgeError.folderUnavailable(path: "/gone") }
        return ProfileSnapshot(source: .markdownFolder(path: "/p"), documents: [ProfileDocument(relativePath: "01.md", text: text)], fingerprint: "fp-\(text)", estimatedTokens: 1, sizeStatus: .ok)
    }

    func realtimeDigest() -> String { "" }
    func relevantContext(for query: String, tokenBudget: Int) throws -> [ProfileDocument] { try snapshot().documents }
    func transcriptionKeywords() -> [String] { [] }
}

@Suite struct SessionProfileFreezerTests {
    @Test func startFreezesSnapshotAndWritesDigest() async throws {
        let profile = FakeProfile()
        let repository = InMemorySessionRepository()
        let freezer = SessionProfileFreezer(provider: profile, repository: repository)
        let id = SessionID()
        await freezer.handle(.started(id, resumed: false))
        #expect(try await repository.knowledgeDigest(sessionID: id) == "fp-v1")
        await profile.set("v2")
        let frozen = await freezer.snapshot(for: id)
        #expect(frozen?.documents.first?.text == "v1")
        #expect(try await repository.knowledgeDigest(sessionID: id) == "fp-v1")
        #expect(await profile.snapshotCalls == 1)
    }

    @Test func nextSessionSeesNewContent() async throws {
        let profile = FakeProfile()
        let repository = InMemorySessionRepository()
        let freezer = SessionProfileFreezer(provider: profile, repository: repository)
        let first = SessionID()
        let second = SessionID()
        await freezer.handle(.started(first, resumed: false))
        await profile.set("v2")
        await freezer.handle(.stopped(first, reason: .user))
        await freezer.handle(.started(second, resumed: false))
        #expect(try await repository.knowledgeDigest(sessionID: second) == "fp-v2")
        #expect(await freezer.frozenSessionIDs == [second])
    }

    @Test func snapshotForUnfrozenSessionFreezesOnDemand() async throws {
        let profile = FakeProfile()
        let repository = InMemorySessionRepository()
        let freezer = SessionProfileFreezer(provider: profile, repository: repository)
        let id = SessionID()
        #expect(await freezer.snapshot(for: id)?.fingerprint == "fp-v1")
        #expect(try await repository.knowledgeDigest(sessionID: id) == "fp-v1")
    }

    @Test func failureLeavesNoDigestAndRetriesLater() async throws {
        let profile = FakeProfile()
        await profile.setFailing(true)
        let repository = InMemorySessionRepository()
        let logs = LockedLog()
        let freezer = SessionProfileFreezer(provider: profile, repository: repository, redactedLog: { logs.append($0) })
        let id = SessionID()
        await freezer.handle(.started(id, resumed: false))
        #expect(try await repository.knowledgeDigest(sessionID: id) == nil)
        #expect(logs.lines.contains { $0.contains("profile freeze failed") })
        await profile.setFailing(false)
        #expect(await freezer.snapshot(for: id)?.fingerprint == "fp-v1")
    }

    @Test func observesCoordinatorEvents() async throws {
        let profile = FakeProfile()
        let repository = InMemorySessionRepository()
        let freezer = SessionProfileFreezer(provider: profile, repository: repository)
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
        await freezer.observe(stream)
        let id = SessionID()
        continuation.yield(.started(id, resumed: false))
        await waitUntil { (try? await repository.knowledgeDigest(sessionID: id)) == "fp-v1" }
        #expect(try await repository.knowledgeDigest(sessionID: id) == "fp-v1")
        continuation.yield(.discarded(id))
        await waitUntil { await freezer.frozenSessionIDs.isEmpty }
        #expect(await freezer.frozenSessionIDs.isEmpty)
        continuation.finish()
        await freezer.stopObserving()
    }
}

private final class LockedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func append(_ line: String) { lock.withLock { _lines.append(line) } }
    var lines: [String] { lock.withLock { _lines } }
}
