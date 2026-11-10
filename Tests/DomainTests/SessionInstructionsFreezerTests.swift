import Foundation
import Testing
@testable import Domain

private actor Recorder: SessionInstructionRecording {
    private(set) var writes: [(SessionID, InstructionProfile, RealtimeDigestSource)] = []
    func setInstructionProfile(sessionID: SessionID, profile: InstructionProfile, digestSource: RealtimeDigestSource) { writes.append((sessionID, profile, digestSource)) }
    func instructionProfile(sessionID: SessionID) -> InstructionProfile? { writes.last { $0.0 == sessionID }?.1 }
    var count: Int { writes.count }
}

private final class Builds: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

@Suite struct SessionInstructionsFreezerTests {
    @Test func instructionsAreFrozenWithinSessionAndRecordedOnce() async {
        let recorder = Recorder()
        let freezer = SessionInstructionsFreezer(recorder: recorder)
        let builds = Builds()
        let session = SessionID()
        let first = await freezer.instructions(for: session) { (.bilingualAssist, .cached, "text-\(builds.next())") }
        let second = await freezer.instructions(for: session) { (.interviewFirstPerson, .legacy, "text-\(builds.next())") }
        #expect(first == "text-1")
        #expect(second == "text-1")
        #expect(builds.count == 1)
        #expect(await recorder.count == 1)
        #expect(await recorder.instructionProfile(sessionID: session) == .bilingualAssist)
    }

    @Test func nextSessionPicksUpNewProfileAndNilSessionIsNotCached() async {
        let recorder = Recorder()
        let freezer = SessionInstructionsFreezer(recorder: recorder)
        let builds = Builds()
        let a = SessionID()
        _ = await freezer.instructions(for: a) { (.interviewFirstPerson, .legacy, "a-\(builds.next())") }
        await freezer.forget(a)
        let b = SessionID()
        #expect(await freezer.instructions(for: b) { (.bilingualAssist, .file, "b-\(builds.next())") } == "b-2")
        #expect(await freezer.instructions(for: nil) { (.bilingualAssist, .file, "n-\(builds.next())") } == "n-3")
        #expect(await freezer.instructions(for: nil) { (.bilingualAssist, .file, "n-\(builds.next())") } == "n-4")
        #expect(await recorder.count == 2)
    }
}
