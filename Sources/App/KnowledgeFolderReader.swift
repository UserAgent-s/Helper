import Domain
import Foundation

struct KnowledgeFolderReader: KnowledgeFolderReading {
    static let allowedExtensions: Set<String> = ["md", "txt", "markdown"]
    static let maxBytes = KnowledgeBaseViewModel.maxImportBytes

    let directory: URL

    func readFiles() async throws -> [KnowledgeFile] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        var files: [KnowledgeFile] = []
        for entry in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                for nested in try fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    let nestedIsDirectory = (try? nested.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    guard !nestedIsDirectory, let file = Self.read(nested, relativePath: entry.lastPathComponent + "/" + nested.lastPathComponent) else { continue }
                    files.append(file)
                }
            } else if let file = Self.read(entry, relativePath: entry.lastPathComponent) {
                files.append(file)
            }
        }
        return files
    }

    private static func read(_ url: URL, relativePath: String) -> KnowledgeFile? {
        guard allowedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { return nil }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        return KnowledgeFile(relativePath: relativePath, content: text)
    }
}
