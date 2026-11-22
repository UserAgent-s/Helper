import Domain
import Foundation
import Testing
@testable import ProfileKnowledge

private final class DomainConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProfileFolderConfiguration

    init(_ value: ProfileFolderConfiguration) {
        self.value = value
    }

    var config: ProfileFolderConfiguration {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@Suite struct ExpertDomainTests {
    private func makeFolder() throws -> ProfileTestFolder {
        let folder = try ProfileTestFolder()
        try folder.write("01_ABOUT.md", "# About")
        try folder.write("CV/cv.md", "cv")
        try folder.write("Domains/PHP/_role.md", "Senior PHP backend engineer.\nAnswer with Symfony examples.")
        try folder.write("Domains/PHP/doctrine.md", "Doctrine notes")
        try folder.write("Domains/PHP/deep/ignored.md", "nested")
        try folder.write("Domains/PHP/notes.txt", "txt")
        try folder.write("Domains/System design/queues.md", "Backpressure notes")
        try folder.write("Domains/Empty/readme.txt", "no md")
        try folder.write("Domains/loose.md", "not a domain")
        return folder
    }

    private func provider(_ box: DomainConfigBox, limits: ProfileLimits = .standard) -> MarkdownFolderProfileProvider {
        MarkdownFolderProfileProvider(limits: limits, configuration: { box.config }, legacyText: { "" })
    }

    @Test func scannerFindsDomainSubfoldersWithMarkdownOnly() throws {
        let folder = try makeFolder()
        defer { folder.remove() }
        let domains = ExpertDomainScanner.scan(folder.url)
        #expect(domains.map(\.name) == ["PHP", "System design"])
        #expect(domains[0].hasRole)
        #expect(domains[0].files.map(\.relativePath) == ["Domains/PHP/_role.md", "Domains/PHP/doctrine.md"])
        #expect(domains[1].hasRole == false)
    }

    @Test func domainFilesAreNotProfileCandidates() async throws {
        let folder = try makeFolder()
        defer { folder.remove() }
        let box = DomainConfigBox(ProfileFolderConfiguration(folder: folder.url, selectedPaths: nil))
        let candidates = try await provider(box).candidates()
        #expect(candidates.map(\.relativePath) == ["01_ABOUT.md", "CV/cv.md"])
    }

    @Test func allDomainsActiveUntilOwnerChooses() async throws {
        let folder = try makeFolder()
        defer { folder.remove() }
        let box = DomainConfigBox(ProfileFolderConfiguration(folder: folder.url, selectedPaths: nil))
        let snapshot = try await provider(box).snapshot()
        #expect(snapshot.domains.map(\.name) == ["PHP", "System design"])
        let php = try #require(snapshot.domains.first)
        #expect(php.role == "Senior PHP backend engineer.\nAnswer with Symfony examples.")
        #expect(php.documents.map(\.relativePath) == ["Domains/PHP/doctrine.md"])
        #expect(snapshot.documents.map(\.relativePath) == ["01_ABOUT.md"])
    }

    @Test func inactiveDomainsAreNotInSnapshotAndDoNotChangeFingerprint() async throws {
        let folder = try makeFolder()
        defer { folder.remove() }
        let box = DomainConfigBox(ProfileFolderConfiguration(folder: folder.url, selectedPaths: nil))
        let all = try await provider(box).snapshot()
        box.config = ProfileFolderConfiguration(folder: folder.url, selectedPaths: nil, activeDomains: ["System design"])
        let one = try await provider(box).snapshot()
        #expect(one.domains.map(\.name) == ["System design"])
        #expect(one.fingerprint == all.fingerprint)
        box.config = ProfileFolderConfiguration(folder: folder.url, selectedPaths: nil, activeDomains: [])
        let none = try await provider(box).snapshot()
        #expect(none.domains.isEmpty)
    }

    @Test func domainsOverLimitFailLoudly() async throws {
        let folder = try makeFolder()
        defer { folder.remove() }
        try folder.write("Domains/PHP/big.md", String(repeating: "x", count: 2_000))
        let box = DomainConfigBox(ProfileFolderConfiguration(folder: folder.url, selectedPaths: nil))
        await #expect(throws: ProfileKnowledgeError.self) {
            try await provider(box, limits: ProfileLimits(domainMaxBytes: 1_000)).snapshot()
        }
    }

    @Test func noFolderMeansNoDomains() async throws {
        let box = DomainConfigBox(ProfileFolderConfiguration(folder: nil, selectedPaths: nil, activeDomains: ["PHP"]))
        let snapshot = try await provider(box).snapshot()
        #expect(snapshot.domains.isEmpty)
        #expect(await provider(box).domainCandidates().isEmpty)
    }
}
