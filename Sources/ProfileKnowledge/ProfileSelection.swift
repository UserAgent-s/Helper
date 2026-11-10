import Foundation

public enum ProfileSelection {
    public static let canonicalPrefixes = ["01_", "02_", "03_"]

    public static func defaultPaths(for candidates: [ProfileCandidate]) -> Set<String> {
        let topLevel = candidates.filter { $0.depth == 1 }
        let canonical = topLevel.filter { candidate in canonicalPrefixes.contains { candidate.relativePath.hasPrefix($0) } }
        return Set((canonical.isEmpty ? topLevel : canonical).map(\.relativePath))
    }

    public static func effectivePaths(stored: Set<String>?, candidates: [ProfileCandidate]) -> [String] {
        let available = Set(candidates.map(\.relativePath))
        let chosen = stored ?? defaultPaths(for: candidates)
        return candidates.map(\.relativePath).filter { chosen.contains($0) && available.contains($0) }
    }
}
