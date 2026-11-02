import Foundation
import Testing
@testable import Domain

@Suite struct ExpertDomainSeedingTests {
    @Test func legacyProfileActivatesMatchingBuiltInOnly() {
        let php = ExpertDomainPresets.seedPlan(existing: [], legacyProfile: .phpBackend)
        #expect(php.count == 3)
        #expect(php.first { $0.id == ExpertDomainPresets.phpBackendID }?.isActive == true)
        #expect(php.first { $0.id == ExpertDomainPresets.systemDesignID }?.isActive == false)
        #expect(php.first { $0.id == ExpertDomainPresets.behavioralID }?.isActive == false)

        let design = ExpertDomainPresets.seedPlan(existing: [], legacyProfile: .systemDesign)
        #expect(design.filter(\.isActive).map(\.id) == [ExpertDomainPresets.systemDesignID])

        let behavioral = ExpertDomainPresets.seedPlan(existing: [], legacyProfile: .behavioral)
        #expect(behavioral.filter(\.isActive).map(\.id) == [ExpertDomainPresets.behavioralID])
    }

    @Test func automaticOrMissingProfileActivatesAllBuiltIns() {
        for profile in [LegacyAnswerProfile.automatic, nil] {
            let plan = ExpertDomainPresets.seedPlan(existing: [], legacyProfile: profile)
            #expect(plan.count == 3)
            #expect(plan.allSatisfy { $0.isActive })
        }
    }

    @Test func seedingIsIdempotent() {
        let first = ExpertDomainPresets.seedPlan(existing: [], legacyProfile: nil)
        let again = ExpertDomainPresets.seedPlan(existing: first, legacyProfile: nil)
        #expect(again.isEmpty)
        let partial = ExpertDomainPresets.seedPlan(existing: [ExpertDomainPresets.phpBackend], legacyProfile: nil)
        #expect(partial.map(\.id) == [ExpertDomainPresets.systemDesignID, ExpertDomainPresets.behavioralID])
    }

    @Test func libraryStopsSeedingOnceMarked() async {
        let notes = InMemoryKnowledgeNotes()
        let domains = InMemoryExpertDomains()
        let flag = SeedFlag()
        let library = KnowledgeLibrary(
            notes: notes,
            domains: domains,
            seedPolicy: KnowledgeSeedPolicy(isSeeded: { flag.value }, legacyProfile: { .phpBackend }, markSeeded: { flag.value = true })
        )
        let snapshot = await library.refresh()
        #expect(snapshot.domains.count == 3)
        #expect(snapshot.activeDomains.map(\.id) == [ExpertDomainPresets.phpBackendID])
        await library.deleteDomain(id: ExpertDomainPresets.behavioralID)
        let after = await library.refresh()
        #expect(after.domains.count == 2)
    }
}

@Suite struct ExpertAreasInstructionsTests {
    @Test func activeAreasAppearInOneSectionInactiveDoNot() {
        var inactive = ExpertDomainPresets.behavioral
        inactive.isActive = false
        let custom = ExpertDomain(name: "Kubernetes", role: "A platform engineer.", guidance: "- Talk about control plane and workloads.", sortOrder: 9)
        let text = AnswerInstructionsBuilder.build(adaptation: .transcriptText, length: .standard, domains: [ExpertDomainPresets.phpBackend, inactive, custom], candidate: .empty)
        #expect(text.components(separatedBy: "# Expert areas").count == 2)
        #expect(text.contains("## PHP / Backend"))
        #expect(text.contains("## Kubernetes"))
        #expect(text.contains("control plane and workloads"))
        #expect(!text.contains("## Behavioral"))
        #expect(!text.contains("Never invent a story"))
        #expect(!text.contains("# Interview focus"))
    }

    @Test func emptyAreasFallBackToAutomaticInterviewFocus() {
        let text = AnswerInstructionsBuilder.build(adaptation: .realtimeAudio, length: .standard, domains: [], candidate: .empty)
        #expect(text.contains("# Interview focus"))
        #expect(!text.contains("# Expert areas"))
        var allInactive = ExpertDomainPresets.interviewBuiltIns
        for index in allInactive.indices { allInactive[index].isActive = false }
        #expect(AnswerInstructionsBuilder.build(adaptation: .realtimeAudio, length: .standard, domains: allInactive, candidate: .empty).contains("# Interview focus"))
    }

    @Test func builtInsReproduceFormerProfileGuidance() {
        let text = AnswerInstructionsBuilder.build(adaptation: .transcriptText, length: .standard, domains: ExpertDomainPresets.interviewBuiltIns, candidate: .empty)
        #expect(text.contains("PHP-FPM and OPcache behaviour"))
        #expect(text.contains("justify every added component"))
        #expect(text.contains("Never invent a story, a team, an employer, a metric, or an outcome."))
    }
}

@Suite struct KnowledgeContextDomainsTests {
    @Test func notesOfInactiveDomainsNeverReachInstructions() {
        var inactive = ExpertDomainPresets.systemDesign
        inactive.isActive = false
        let notes = [
            KnowledgeNote(title: "Resume", content: "Shared resume text"),
            KnowledgeNote(title: "Queues", content: "SQS retry notes", domainID: ExpertDomainPresets.phpBackendID),
            KnowledgeNote(title: "CAP", content: "SECRET-DESIGN-NOTE", domainID: inactive.id),
            KnowledgeNote(title: "Off", content: "disabled note", isEnabled: false, domainID: ExpertDomainPresets.phpBackendID),
        ]
        let context = KnowledgeContextBuilder.build(notes, domains: [ExpertDomainPresets.phpBackend, inactive])
        #expect(context.text.contains("## Resume\nShared resume text"))
        #expect(context.text.contains("## [PHP / Backend] Queues\nSQS retry notes"))
        #expect(!context.text.contains("SECRET-DESIGN-NOTE"))
        #expect(!context.text.contains("disabled note"))
        #expect(context.includedNoteCount == 2)
        #expect(context.excludedByInactiveDomainCount == 1)
        #expect(context.activeDomainNames == ["PHP / Backend"])
        let instructions = AnswerInstructionsBuilder.build(adaptation: .transcriptText, length: .standard, domains: [ExpertDomainPresets.phpBackend, inactive], candidate: .empty, knowledge: context)
        #expect(!instructions.contains("SECRET-DESIGN-NOTE"))
    }

    @Test func notesOfUnknownDomainFallBackToShared() {
        let orphan = KnowledgeNote(title: "Orphan", content: "kept", domainID: UUID())
        let context = KnowledgeContextBuilder.build([orphan], domains: [ExpertDomainPresets.phpBackend])
        #expect(context.text.contains("## Orphan\nkept"))
    }

    @Test func budgetIsSharedAcrossAreas() {
        let notes = [
            KnowledgeNote(title: "A", content: String(repeating: "a", count: 700)),
            KnowledgeNote(title: "B", content: String(repeating: "b", count: 700), domainID: ExpertDomainPresets.phpBackendID),
        ]
        let context = KnowledgeContextBuilder.build(notes, domains: [ExpertDomainPresets.phpBackend], budgetCharacters: 1_000)
        #expect(context.truncatedNoteCount >= 1)
        #expect(context.text.count <= 1_100)
    }

    @Test func liveContextFingerprintTracksDomainActivation() {
        let live = LiveAnswerContext()
        live.update(domains: ExpertDomainPresets.interviewBuiltIns)
        let before = live.fingerprint
        var toggled = ExpertDomainPresets.interviewBuiltIns
        toggled[0].isActive = false
        live.update(domains: toggled)
        #expect(live.fingerprint != before)
        #expect(live.activeDomainNames == ["System Design", "Behavioral"])
    }
}

@Suite struct KnowledgeFolderSyncPlanTests {
    @Test func rootFilesBecomeSharedNotesAndSubfoldersCreateAreas() {
        let files = [
            KnowledgeFile(relativePath: "resume.md", content: "# Resume\nPHP"),
            KnowledgeFile(relativePath: "Kubernetes/control-plane.md", content: "etcd, scheduler"),
            KnowledgeFile(relativePath: "Kubernetes/empty.md", content: "   \n"),
        ]
        let plan = KnowledgeFolderSyncPlan.make(files: files, existingNotes: [], domains: ExpertDomainPresets.interviewBuiltIns, now: Date(timeIntervalSince1970: 100))
        #expect(plan.domainsToCreate.map(\.name) == ["Kubernetes"])
        #expect(plan.domainsToCreate.first?.isActive == true)
        #expect(plan.domainsToCreate.first?.sortOrder == 3)
        #expect(plan.notesToSave.count == 2)
        let shared = plan.notesToSave.first { $0.title == "resume" }
        #expect(shared?.domainID == nil)
        #expect(shared?.origin == .folder)
        #expect(shared?.sourceFileName == "resume.md")
        let nested = plan.notesToSave.first { $0.title == "control-plane" }
        #expect(nested?.domainID == plan.domainsToCreate.first?.id)
        #expect(plan.noteIDsToDelete.isEmpty)
    }

    @Test func existingAreaIsMatchedIgnoringCasePunctuationAndDiacritics() {
        for folder in ["php-backend", "PHP Backend", "php_backend"] {
            let files = [KnowledgeFile(relativePath: "\(folder)/notes.md", content: "x")]
            let plan = KnowledgeFolderSyncPlan.make(files: files, existingNotes: [], domains: ExpertDomainPresets.interviewBuiltIns)
            #expect(plan.domainsToCreate.isEmpty)
            #expect(plan.notesToSave.first?.domainID == ExpertDomainPresets.phpBackendID)
        }
        let kyiv = ExpertDomain(name: "Київ")
        #expect(kyiv.matches(folderName: "київ"))
        #expect(ExpertDomain.folderKey("PHP / Backend") == "phpbackend")
    }

    @Test func unchangedFilesAreSkippedChangedFilesKeepDisabledState() {
        let path = "Kubernetes/notes.md"
        let id = KnowledgeFolderSyncPlan.noteID(forRelativePath: path)
        let domain = ExpertDomain(name: "Kubernetes")
        let existing = KnowledgeNote(id: id, title: "notes", content: "old", isEnabled: false, sourceFileName: path, domainID: domain.id, origin: .folder)
        let unchanged = KnowledgeFolderSyncPlan.make(files: [KnowledgeFile(relativePath: path, content: "old\n")], existingNotes: [existing], domains: [domain])
        #expect(unchanged.isEmpty)
        let changed = KnowledgeFolderSyncPlan.make(files: [KnowledgeFile(relativePath: path, content: "new")], existingNotes: [existing], domains: [domain])
        #expect(changed.notesToSave.count == 1)
        #expect(changed.notesToSave.first?.id == id)
        #expect(changed.notesToSave.first?.isEnabled == false)
        #expect(changed.notesToSave.first?.content == "new")
    }

    @Test func removedFilesDeleteOnlyFolderNotes() {
        let folderNote = KnowledgeNote(id: KnowledgeFolderSyncPlan.noteID(forRelativePath: "gone.md"), title: "gone", content: "x", sourceFileName: "gone.md", origin: .folder)
        let manualNote = KnowledgeNote(title: "manual", content: "keep")
        let plan = KnowledgeFolderSyncPlan.make(files: [], existingNotes: [folderNote, manualNote], domains: [])
        #expect(plan.noteIDsToDelete == [folderNote.id])
    }

    @Test func noteIDIsStableAndDistinct() {
        #expect(KnowledgeFolderSyncPlan.noteID(forRelativePath: "a/b.md") == KnowledgeFolderSyncPlan.noteID(forRelativePath: "a/b.md"))
        #expect(KnowledgeFolderSyncPlan.noteID(forRelativePath: "a/b.md") != KnowledgeFolderSyncPlan.noteID(forRelativePath: "a/c.md"))
    }

    @Test func libraryAppliesPlanThroughRepositories() async {
        let notes = InMemoryKnowledgeNotes()
        let domains = InMemoryExpertDomains()
        let folder = FakeFolder(files: [KnowledgeFile(relativePath: "Rust/ownership.md", content: "borrow checker")])
        let library = KnowledgeLibrary(notes: notes, domains: domains, folder: folder)
        let first = await library.refresh()
        #expect(first.domains.map(\.name) == ["Rust"])
        #expect(first.notes.count == 1)
        #expect(first.context.text.contains("## [Rust] ownership\nborrow checker"))
        folder.files = []
        let second = await library.refresh()
        #expect(second.notes.isEmpty)
        #expect(second.domains.map(\.name) == ["Rust"])
    }
}

final class SeedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class FakeFolder: KnowledgeFolderReading, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [KnowledgeFile]
    init(files: [KnowledgeFile]) { stored = files }
    var files: [KnowledgeFile] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func readFiles() async throws -> [KnowledgeFile] { files }
}

actor InMemoryKnowledgeNotes: KnowledgeNoteRepository {
    private var storage: [UUID: KnowledgeNote] = [:]
    func save(_ note: KnowledgeNote) async throws { storage[note.id] = note }
    func delete(id: UUID) async throws { storage[id] = nil }
    func all() async throws -> [KnowledgeNote] { storage.values.sorted { $0.updatedAt < $1.updatedAt } }
}

actor InMemoryExpertDomains: ExpertDomainRepository {
    private var storage: [UUID: ExpertDomain] = [:]
    func save(_ domain: ExpertDomain) async throws { storage[domain.id] = domain }
    func delete(id: UUID) async throws { storage[id] = nil }
    func all() async throws -> [ExpertDomain] { storage.values.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) } }
}
