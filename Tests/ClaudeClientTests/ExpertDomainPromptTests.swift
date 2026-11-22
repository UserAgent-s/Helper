import Domain
import Foundation
import Testing
@testable import ClaudeClient

@Suite struct ExpertDomainPromptTests {
    private func snapshot(documents: [ProfileDocument], domains: [ExpertDomain]) -> ProfileSnapshot {
        ProfileSnapshot(source: .markdownFolder(path: "/p"), documents: documents, fingerprint: "f", estimatedTokens: 1, sizeStatus: .ok, domains: domains)
    }

    @Test func activeDomainsFollowProfileInCachedBlock() throws {
        let php = ExpertDomain(name: "PHP", role: "Senior PHP engineer", documents: [ProfileDocument(relativePath: "Domains/PHP/doctrine.md", text: "Doctrine notes")])
        let block = try #require(ClaudePromptBuilder.profileBlock(snapshot(documents: [ProfileDocument(relativePath: "01.md", text: "me")], domains: [php])))
        let profileRange = try #require(block.range(of: "</profile>"))
        let domainsRange = try #require(block.range(of: "<domains>"))
        #expect(profileRange.upperBound <= domainsRange.lowerBound)
        #expect(block.contains("<domain name=\"PHP\">\n<role>\nSenior PHP engineer\n</role>"))
        #expect(block.contains("<document path=\"Domains/PHP/doctrine.md\">\nDoctrine notes\n</document>"))
        let system = ClaudePromptBuilder.system(profile: snapshot(documents: [], domains: [php]))
        #expect(system.count == 2)
        #expect(system[0].text.contains("<domains>"))
    }

    @Test func noDomainsKeepsPreviousBlockAndOnlyDomainsStillSend() throws {
        let plain = try #require(ClaudePromptBuilder.profileBlock(snapshot(documents: [ProfileDocument(relativePath: "01.md", text: "me")], domains: [])))
        #expect(plain == "<profile>\n<document path=\"01.md\">\nme\n</document>\n</profile>")
        let onlyDomains = ClaudePromptBuilder.profileBlock(snapshot(documents: [], domains: [ExpertDomain(name: "QA", role: nil, documents: [])]))
        #expect(onlyDomains == "<domains>\n<domain name=\"QA\">\n</domain>\n</domains>")
        #expect(ClaudePromptBuilder.profileBlock(snapshot(documents: [], domains: [])) == nil)
    }
}
