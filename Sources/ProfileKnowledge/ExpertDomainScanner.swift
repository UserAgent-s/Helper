import Foundation

public struct ExpertDomainCandidate: Sendable, Equatable, Identifiable {
    public let name: String
    public let hasRole: Bool
    public let files: [ProfileCandidate]

    public var id: String { name }

    public var byteCount: Int { files.reduce(0) { $0 + $1.byteCount } }
}

public enum ExpertDomainScanner {
    public static let folderName = "Domains"
    public static let roleFileName = "_role.md"

    public static func scan(_ profileFolder: URL, fileManager: FileManager = .default) -> [ExpertDomainCandidate] {
        let root = profileFolder.appendingPathComponent(folderName, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var result: [ExpertDomainCandidate] = []
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true, values.isDirectory == true else { continue }
            let name = entry.lastPathComponent.precomposedStringWithCanonicalMapping
            let files = markdownFiles(in: entry, domain: name, keys: keys, fileManager: fileManager)
            guard !files.isEmpty else { continue }
            let rolePath = path(domain: name, file: roleFileName)
            result.append(ExpertDomainCandidate(name: name, hasRole: files.contains { $0.relativePath == rolePath }, files: files))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func path(domain: String, file: String) -> String {
        [folderName, domain, file].joined(separator: "/")
    }

    public static func isDomainPath(_ relativePath: String) -> Bool {
        relativePath.hasPrefix(folderName + "/")
    }

    private static func markdownFiles(in directory: URL, domain: String, keys: [URLResourceKey], fileManager: FileManager) -> [ProfileCandidate] {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var files: [ProfileCandidate] = []
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true, values.isRegularFile == true, entry.pathExtension.lowercased() == "md" else { continue }
            let name = entry.lastPathComponent.precomposedStringWithCanonicalMapping
            let isRole = name.lowercased() == roleFileName
            files.append(ProfileCandidate(relativePath: path(domain: domain, file: isRole ? roleFileName : name), byteCount: values.fileSize ?? 0))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }
}
