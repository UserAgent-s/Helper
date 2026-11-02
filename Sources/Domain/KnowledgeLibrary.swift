import Foundation

public struct KnowledgeFile: Sendable, Equatable {
    public let relativePath: String
    public let content: String

    public init(relativePath: String, content: String) {
        self.relativePath = relativePath
        self.content = content
    }
}

public protocol KnowledgeFolderReading: Sendable {
    func readFiles() async throws -> [KnowledgeFile]
}

public struct KnowledgeFolderSyncPlan: Sendable, Equatable {
    public var notesToSave: [KnowledgeNote]
    public var noteIDsToDelete: [UUID]
    public var domainsToCreate: [ExpertDomain]

    public var isEmpty: Bool {
        notesToSave.isEmpty && noteIDsToDelete.isEmpty && domainsToCreate.isEmpty
    }

    public static func noteID(forRelativePath path: String) -> UUID {
        let normalized = path.precomposedStringWithCanonicalMapping
        var high: UInt64 = 0xcbf29ce484222325
        var low: UInt64 = 0x84222325cbf29ce4
        for byte in normalized.utf8 {
            high ^= UInt64(byte)
            high = high &* 0x100000001b3
            low ^= UInt64(byte &+ 0x9e)
            low = low &* 0x100000001b3
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: high >> (8 * UInt64(index)))
            bytes[8 + index] = UInt8(truncatingIfNeeded: low >> (8 * UInt64(index)))
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public static func make(files: [KnowledgeFile], existingNotes: [KnowledgeNote], domains: [ExpertDomain], now: Date = Date()) -> KnowledgeFolderSyncPlan {
        var plan = KnowledgeFolderSyncPlan(notesToSave: [], noteIDsToDelete: [], domainsToCreate: [])
        let existingByID = Dictionary(uniqueKeysWithValues: existingNotes.map { ($0.id, $0) })
        var nextSortOrder = (domains.map(\.sortOrder).max() ?? -1) + 1
        var seenIDs = Set<UUID>()

        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            let content = file.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            let components = file.relativePath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard let fileName = components.last else { continue }
            let title = (fileName as NSString).deletingPathExtension
            var domainID: UUID?
            if components.count >= 2 {
                let folder = components[0]
                if let known = domains.first(where: { $0.matches(folderName: folder) }) ?? plan.domainsToCreate.first(where: { $0.matches(folderName: folder) }) {
                    domainID = known.id
                } else {
                    let created = ExpertDomain(name: folder, isActive: true, sortOrder: nextSortOrder, updatedAt: now)
                    nextSortOrder += 1
                    plan.domainsToCreate.append(created)
                    domainID = created.id
                }
            }
            let id = noteID(forRelativePath: file.relativePath)
            seenIDs.insert(id)
            if let existing = existingByID[id],
               existing.content == content, existing.title == title, existing.domainID == domainID, existing.origin == .folder {
                continue
            }
            plan.notesToSave.append(KnowledgeNote(
                id: id,
                title: title,
                content: content,
                isEnabled: existingByID[id]?.isEnabled ?? true,
                sourceFileName: file.relativePath,
                domainID: domainID,
                origin: .folder,
                updatedAt: now
            ))
        }

        plan.noteIDsToDelete = existingNotes
            .filter { $0.origin == .folder && !seenIDs.contains($0.id) }
            .map(\.id)
        return plan
    }
}

public struct KnowledgeSeedPolicy: Sendable {
    public let isSeeded: @Sendable () -> Bool
    public let legacyProfile: @Sendable () -> LegacyAnswerProfile?
    public let markSeeded: @Sendable () -> Void

    public init(
        isSeeded: @escaping @Sendable () -> Bool,
        legacyProfile: @escaping @Sendable () -> LegacyAnswerProfile?,
        markSeeded: @escaping @Sendable () -> Void
    ) {
        self.isSeeded = isSeeded
        self.legacyProfile = legacyProfile
        self.markSeeded = markSeeded
    }

    public static let disabled = KnowledgeSeedPolicy(isSeeded: { true }, legacyProfile: { nil }, markSeeded: {})
}

public struct KnowledgeLibrarySnapshot: Sendable, Equatable {
    public let domains: [ExpertDomain]
    public let notes: [KnowledgeNote]
    public let context: KnowledgeContext
    public let lastSyncSummary: String?

    public static let empty = KnowledgeLibrarySnapshot(domains: [], notes: [], context: .empty, lastSyncSummary: nil)

    public var activeDomains: [ExpertDomain] {
        domains.filter(\.isActive)
    }

    public func noteCount(for domain: ExpertDomain) -> Int {
        notes.filter { $0.domainID == domain.id }.count
    }
}

public actor KnowledgeLibrary {
    private let notes: any KnowledgeNoteRepository
    private let domains: any ExpertDomainRepository
    private let folder: (any KnowledgeFolderReading)?
    private let seedPolicy: KnowledgeSeedPolicy
    private let budgetCharacters: Int
    private var lastSyncSummary: String?

    public init(
        notes: any KnowledgeNoteRepository,
        domains: any ExpertDomainRepository,
        folder: (any KnowledgeFolderReading)? = nil,
        seedPolicy: KnowledgeSeedPolicy = .disabled,
        budgetCharacters: Int = KnowledgeContextBuilder.defaultBudgetCharacters
    ) {
        self.notes = notes
        self.domains = domains
        self.folder = folder
        self.seedPolicy = seedPolicy
        self.budgetCharacters = budgetCharacters
    }

    public func refresh() async -> KnowledgeLibrarySnapshot {
        await seedIfNeeded()
        await syncFolder()
        return await snapshot()
    }

    public func snapshot() async -> KnowledgeLibrarySnapshot {
        let allDomains = ((try? await domains.all()) ?? []).sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        let allNotes = (try? await notes.all()) ?? []
        return KnowledgeLibrarySnapshot(
            domains: allDomains,
            notes: allNotes,
            context: KnowledgeContextBuilder.build(allNotes, domains: allDomains, budgetCharacters: budgetCharacters),
            lastSyncSummary: lastSyncSummary
        )
    }

    public func saveNote(_ note: KnowledgeNote) async {
        try? await notes.save(note)
    }

    public func deleteNote(id: UUID) async {
        try? await notes.delete(id: id)
    }

    public func saveDomain(_ domain: ExpertDomain) async {
        var stored = domain
        stored.updatedAt = Date()
        if stored.trimmedName.isEmpty { stored.name = "Area" }
        try? await domains.save(stored)
    }

    public func deleteDomain(id: UUID) async {
        try? await domains.delete(id: id)
    }

    public func syncFolder() async {
        guard let folder else { return }
        let files: [KnowledgeFile]
        do {
            files = try await folder.readFiles()
        } catch {
            lastSyncSummary = "folder_unreadable"
            return
        }
        let existingNotes = (try? await notes.all()) ?? []
        let existingDomains = (try? await domains.all()) ?? []
        let plan = KnowledgeFolderSyncPlan.make(files: files, existingNotes: existingNotes, domains: existingDomains)
        for domain in plan.domainsToCreate {
            try? await domains.save(domain)
        }
        for note in plan.notesToSave {
            try? await notes.save(note)
        }
        for id in plan.noteIDsToDelete {
            try? await notes.delete(id: id)
        }
        lastSyncSummary = "files=\(files.count) saved=\(plan.notesToSave.count) removed=\(plan.noteIDsToDelete.count) areas_created=\(plan.domainsToCreate.count)"
    }

    private func seedIfNeeded() async {
        guard !seedPolicy.isSeeded() else { return }
        let existing = (try? await domains.all()) ?? []
        for domain in ExpertDomainPresets.seedPlan(existing: existing, legacyProfile: seedPolicy.legacyProfile()) {
            try? await domains.save(domain)
        }
        seedPolicy.markSeeded()
    }
}
