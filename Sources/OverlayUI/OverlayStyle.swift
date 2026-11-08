import AppKit

public enum OverlayStyle: String, CaseIterable, Codable, Sendable {
    case pinned, floating, fullscreen
}

public enum OverlayFontFamily: String, CaseIterable, Codable, Sendable {
    case sans, serif, mono

    func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        switch self {
        case .sans:
            return base
        case .serif:
            guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
            return NSFont(descriptor: descriptor, size: size) ?? base
        case .mono:
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
    }
}
