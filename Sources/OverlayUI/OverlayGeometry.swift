import CoreGraphics

enum OverlayGeometry {
    static func pinnedOrigin(for size: CGSize, screenFrame: CGRect) -> CGPoint {
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.maxY - size.height
        return CGPoint(x: x, y: y)
    }
}
