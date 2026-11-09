import Foundation

enum AppFileLocations {
    static let folderName = "UserAgent057"

    static func exportsDirectory(documents: URL) -> URL {
        documents
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
    }

    static func realtimeDiagnosticsLog(library: URL) -> URL {
        library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("realtime_diag.log")
    }

    static func userDirectory(_ directory: FileManager.SearchPathDirectory, fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: directory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
    }
}
