import Foundation

public struct ProfileCandidate: Sendable, Equatable, Identifiable {
    public let relativePath: String
    public let byteCount: Int

    public var id: String { relativePath }

    public var depth: Int { relativePath.split(separator: "/").count }
}

public enum ProfileFolderScanner {
    public static let maxDepth = 2

    public static func scan(_ folder: URL, fileManager: FileManager = .default) throws -> [ProfileCandidate] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProfileScanError.folderUnavailable
        }
        var result: [ProfileCandidate] = []
        try collect(folder, prefix: [], depth: 1, into: &result, fileManager: fileManager)
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private static func collect(_ directory: URL, prefix: [String], depth: Int, into result: inout [ProfileCandidate], fileManager: FileManager) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        for entry in entries {
            let values = try entry.resourceValues(forKeys: Set(keys))
            let name = entry.lastPathComponent.precomposedStringWithCanonicalMapping
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if depth < maxDepth {
                    try collect(entry, prefix: prefix + [name], depth: depth + 1, into: &result, fileManager: fileManager)
                }
            } else if values.isRegularFile == true, entry.pathExtension.lowercased() == "md" {
                result.append(ProfileCandidate(relativePath: (prefix + [name]).joined(separator: "/"), byteCount: values.fileSize ?? 0))
            }
        }
    }
}

public enum ProfileScanError: Error, Equatable {
    case folderUnavailable
}
