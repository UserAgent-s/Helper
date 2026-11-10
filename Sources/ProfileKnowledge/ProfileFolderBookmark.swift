import Foundation

public enum ProfileFolderBookmark {
    public static func make(for folder: URL) throws -> Data {
        try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func resolve(_ data: Data) -> (url: URL, refreshed: Data?)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        return (url, stale ? try? make(for: url) : nil)
    }
}
