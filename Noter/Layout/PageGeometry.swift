import Foundation
import CoreGraphics

/// Converts between PDF page space (points, origin bottom-left, unrotated) and Noter's
/// normalized displayed-page space (0...1, origin top-left, rotation applied).
/// PDF /Rotate values rotate the page clockwise for display.
struct PageGeometry {
    let box: CGRect
    let rotation: Int

    init(box: CGRect, rotation: Int) {
        self.box = box
        self.rotation = ((rotation % 360) + 360) % 360
    }

    func normalized(fromPage p: CGPoint) -> CGPoint {
        let W = max(box.width, 0.0001), H = max(box.height, 0.0001)
        let px = p.x - box.minX, py = box.maxY - p.y
        switch rotation {
        case 90: return CGPoint(x: (H - py) / H, y: px / W)
        case 180: return CGPoint(x: (W - px) / W, y: (H - py) / H)
        case 270: return CGPoint(x: py / H, y: (W - px) / W)
        default: return CGPoint(x: px / W, y: py / H)
        }
    }

    func pagePoint(fromNormalized n: CGPoint) -> CGPoint {
        let W = box.width, H = box.height
        let u = n.x, v = n.y
        switch rotation {
        case 90: return CGPoint(x: box.minX + v * W, y: box.minY + u * H)
        case 180: return CGPoint(x: box.maxX - u * W, y: box.minY + v * H)
        case 270: return CGPoint(x: box.maxX - v * W, y: box.maxY - u * H)
        default: return CGPoint(x: box.minX + u * W, y: box.maxY - v * H)
        }
    }

    func pageRect(fromNormalized r: CGRect) -> CGRect {
        let a = pagePoint(fromNormalized: CGPoint(x: r.minX, y: r.minY))
        let b = pagePoint(fromNormalized: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
