import Foundation

public enum CompanionWebAssets {
    public struct Asset: Sendable {
        public let data: Data
        public let contentType: String
    }

    public static let files: [String: String] = [
        "index.html": "text/html; charset=utf-8",
        "app.css": "text/css; charset=utf-8",
        "app.js": "text/javascript; charset=utf-8",
        "protocol.js": "text/javascript; charset=utf-8",
        "connection.js": "text/javascript; charset=utf-8",
        "store.js": "text/javascript; charset=utf-8",
        "ui.js": "text/javascript; charset=utf-8",
    ]

    public static func fileName(forPath path: String) -> String? {
        let name = path == "/" ? "index.html" : String(path.drop { $0 == "/" })
        return files[name] == nil ? nil : name
    }

    public static func asset(forPath path: String) -> Asset? {
        guard let name = fileName(forPath: path), let contentType = files[name], let data = data(named: name) else { return nil }
        return Asset(data: data, contentType: contentType)
    }

    public static func data(named name: String) -> Data? {
        guard files[name] != nil else { return nil }
        let url = URL(fileURLWithPath: name)
        guard let resource = Bundle.module.url(forResource: url.deletingPathExtension().lastPathComponent, withExtension: url.pathExtension, subdirectory: "Web") else { return nil }
        return try? Data(contentsOf: resource)
    }

    public static func text(named name: String) -> String? {
        data(named: name).map { String(decoding: $0, as: UTF8.self) }
    }
}
