import UIKit

/// One scribble stroke, as the key word detector sees it.
struct InkStrokeInfo {
    /// PencilKit's creation time of the stroke — stable while it's moved, zoomed or
    /// undone, so it identifies the stroke.
    let date: Date
    /// Points along the stroke, normalized to the displayed page (0...1, top-left).
    let points: [CGPoint]
    let color: UIColor
}

/// Finds words you circled or underlined with the scribble pen.
enum InkMarkDetector {
    enum Kind: String {
        case circle, underline
    }

    struct Mark {
        let kind: Kind
        let page: LogicalPage
        let range: ClosedRange<Int>
    }

    /// Longest circled / underlined phrase that counts (a key word is up to 5 words).
    static let maxWords = 6

    static func detect(_ points: [CGPoint], in pages: [LogicalPage]) -> Mark? {
        guard points.count >= 4 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let w = maxX - minX, h = maxY - minY
        var length: CGFloat = 0
        for i in 1..<points.count { length += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y) }
        let ends = hypot(points[points.count - 1].x - points[0].x, points[points.count - 1].y - points[0].y)

        // Underline: flat, fairly straight, wider than it is tall.
        if w >= 0.015, h <= max(0.012, w * 0.2), ends >= length * 0.75 {
            let y = ys.sorted()[ys.count / 2]
            return underlined(minX: minX, maxX: maxX, y: y, in: pages)
        }
        // Circle: a loop that comes back near where it started (or goes all the way round).
        let size = max(w, h)
        if w >= 0.012, h >= 0.006, length >= (w + h) * 1.2, ends <= size * 0.35 || length >= (w + h) * 1.9 {
            return circled(points, in: pages)
        }
        return nil
    }

    /// Words sitting right above the line, on the nearest text line.
    private static func underlined(minX: CGFloat, maxX: CGFloat, y: CGFloat, in pages: [LogicalPage]) -> Mark? {
        var best: (lp: LogicalPage, hits: [(i: Int, gap: CGFloat)])?
        for lp in pages {
            var hits: [(i: Int, gap: CGFloat)] = []
            for (i, t) in lp.tokens.enumerated() {
                let r = t.rect
                guard r.width > 0, r.height > 0 else { continue }
                let overlap = min(r.maxX, maxX) - max(r.minX, minX)
                guard overlap >= r.width * 0.5 else { continue }
                let gap = y - r.maxY // the line is below the word's bottom (a little overlap is fine)
                guard gap >= -r.height * 0.6, gap <= r.height * 0.9 else { continue }
                hits.append((i, gap))
            }
            if hits.count > (best?.hits.count ?? 0) { best = (lp, hits) }
        }
        guard let best, let nearest = best.hits.map(\.gap).min() else { return nil }
        let h = best.lp.tokens[best.hits[0].i].rect.height
        let line = best.hits.filter { $0.gap <= nearest + h * 0.5 }.map(\.i)
        return mark(.underline, best.lp, line)
    }

    /// Words whose middle is inside the loop.
    private static func circled(_ points: [CGPoint], in pages: [LogicalPage]) -> Mark? {
        var best: (lp: LogicalPage, hits: [Int])?
        for lp in pages {
            let hits = lp.tokens.indices.filter { i in
                let r = lp.tokens[i].rect
                return r.width > 0 && inside(CGPoint(x: r.midX, y: r.midY), points)
            }
            if hits.count > (best?.hits.count ?? 0) { best = (lp, hits) }
        }
        guard let best else { return nil }
        return mark(.circle, best.lp, best.hits)
    }

    private static func mark(_ kind: Kind, _ lp: LogicalPage, _ hits: [Int]) -> Mark? {
        guard let lo = hits.min(), let hi = hits.max(), hi - lo + 1 <= maxWords else { return nil }
        // Only real words (not a lone page number or stray mark).
        guard lp.string(for: lo...hi).contains(where: \.isLetter) else { return nil }
        return Mark(kind: kind, page: lp, range: lo...hi)
    }

    /// Ray casting; the stroke is closed with a straight line from its end to its start.
    private static func inside(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var result = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                result.toggle()
            }
            j = i
        }
        return result
    }
}
