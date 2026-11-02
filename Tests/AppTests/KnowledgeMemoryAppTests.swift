import Foundation
import Testing
import Domain
@testable import MeetingAssistant

@MainActor
@Suite struct KnowledgeMemoryAppTests {
    @Test func firstLaunchSeedsBuiltInAreasOnceAndMigratesLegacyProfile() async {
        let environment = makeIsolatedTestEnvironment()
        environment.defaults.set("systemDesign", forKey: "com.local.MeetingAssistant.settings.answerProfile")
        let root = CompositionRoot(environment: environment)
        let snapshot = await root.knowledgeLibrary.refresh()
        #expect(snapshot.domains.count == 3)
        #expect(snapshot.activeDomains.map(\.id) == [ExpertDomainPresets.systemDesignID])
        #expect(root.settingsStore.expertDomainsSeeded)

        await root.knowledgeLibrary.deleteDomain(id: ExpertDomainPresets.phpBackendID)
        let relaunched = CompositionRoot(environment: environment)
        let again = await relaunched.knowledgeLibrary.refresh()
        #expect(again.domains.count == 2)
    }

    @Test func folderFilesBecomeNotesOfAutoCreatedAreaAndEnterInstructions() async throws {
        let environment = makeIsolatedTestEnvironment()
        let root = CompositionRoot(environment: environment)
        let areaFolder = root.knowledgeFolderURL.appendingPathComponent("Kubernetes", isDirectory: true)
        try FileManager.default.createDirectory(at: areaFolder, withIntermediateDirectories: true)
        try "etcd stores cluster state".write(to: areaFolder.appendingPathComponent("control-plane.md"), atomically: true, encoding: .utf8)
        try "shared resume".write(to: root.knowledgeFolderURL.appendingPathComponent("resume.txt"), atomically: true, encoding: .utf8)
        try "ignored".write(to: root.knowledgeFolderURL.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)

        await CompositionRoot.refreshLiveContext(settingsStore: root.settingsStore, library: root.knowledgeLibrary, history: root.questionAnswerRepository)
        let instructions = root.settingsStore.instructions(for: .transcriptText)
        #expect(instructions.contains("## Kubernetes"))
        #expect(instructions.contains("## [Kubernetes] control-plane\netcd stores cluster state"))
        #expect(instructions.contains("## resume\nshared resume"))
        #expect(!instructions.contains("ignored"))
        #expect(root.settingsStore.currentAnswerConfiguration().expertAreas.contains("Kubernetes"))

        try FileManager.default.removeItem(at: areaFolder.appendingPathComponent("control-plane.md"))
        await CompositionRoot.refreshLiveContext(settingsStore: root.settingsStore, library: root.knowledgeLibrary, history: root.questionAnswerRepository)
        #expect(!root.settingsStore.instructions(for: .transcriptText).contains("etcd stores cluster state"))
    }

    @Test func deactivatedAreaKeepsItsNotesOnTheMac() async {
        let environment = makeIsolatedTestEnvironment()
        let root = CompositionRoot(environment: environment)
        _ = await root.knowledgeLibrary.refresh()
        await root.knowledgeLibrary.saveNote(KnowledgeNote(title: "Design", content: "SECRET-DESIGN", domainID: ExpertDomainPresets.systemDesignID))
        var design = ExpertDomainPresets.systemDesign
        design.isActive = false
        await root.knowledgeLibrary.saveDomain(design)
        await CompositionRoot.refreshLiveContext(settingsStore: root.settingsStore, library: root.knowledgeLibrary, history: root.questionAnswerRepository)
        let instructions = root.settingsStore.instructions(for: .realtimeAudio)
        #expect(!instructions.contains("SECRET-DESIGN"))
        #expect(!instructions.contains("## System Design"))
        #expect(instructions.contains("## PHP / Backend"))
    }
}
