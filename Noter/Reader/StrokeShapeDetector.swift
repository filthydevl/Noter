import Foundation
import CoreGraphics

/// Reads the shape of a highlighter stroke: a loop drawn around a word or short phrase
/// (circle), a line drawn under words (underline), or an ordinary highlight. Works in
/// any coordinate space — PDF page (normalized) or Text view (points) — because sizes
/// are measured against the height of the text line.
enum StrokeShapeDetector {
    enum Shape {
        case circle, underline, other
    }

    /// What a highlighter stroke should do with the words around it.
    enum Action {
        /// A circled word or short phrase: a word to define.
        case term(ClosedRange<Int>)
        /// A loop around more than that (a paragraph): highlight what's inside.
        case highlight(ClosedRange<Int>)
        /// A line drawn under words.
        case underline(ClosedRange<Int>)
        /// An ordinary highlight stroke.
        case none
    }

    /// `tokens`: the words near the stroke, in the stroke's coordinate space.
    static func action(_ points: [CGPoint], tokens: [(index: Int, rect: CGRect)]) -> Action {
        switch shape(points, lineHeight: lineHeight(tokens)) {
        case .circle:
            let inside = circled(points, tokens: tokens)
            guard let lo = inside.first, let hi = inside.last else { return .none }
            return isWordOrPhrase(inside, tokens: tokens) ? .term(lo...hi) : .highlight(lo...hi)
        case .underline:
            let above = underlined(points, tokens: tokens)
            guard let lo = above.first, let hi = above.last else { return .none }
            return .underline(lo...hi)
        case .other:
            return .none
        }
    }

    /// Longest circled phrase that counts as one "word" (one line only).
    static let maxCircledWords = 6

    static func shape(_ points: [CGPoint], lineHeight: CGFloat) -> Shape {
        guard points.count >= 4, lineHeight > 0 else { return .other }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .other }
        let w = maxX - minX, h = maxY - minY
        var length: CGFloat = 0
        for i in 1..<points.count { length += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y) }
        let ends = hypot(points[points.count - 1].x - points[0].x, points[points.count - 1].y - points[0].y)

        // Underline: flat and straight, at least about a word long.
        if w >= lineHeight * 0.8, h <= max(lineHeight * 0.6, w * 0.12), ends >= length * 0.8 {
            return .underline
        }
        // Circle: comes back near where it started (or goes all the way round) and
        // encloses an area — a back-and-forth scribble over a line doesn't.
        let size = max(w, h)
        if w >= lineHeight * 0.6, h >= lineHeight * 0.5, length >= (w + h) * 1.2,
           ends <= size * 0.35 || length >= (w + h) * 1.9, area(points) >= w * h * 0.35 {
            return .circle
        }
        return .other
    }

    /// Words whose middle is inside the loop (in book order).
    static func circled(_ points: [CGPoint], tokens: [(index: Int, rect: CGRect)]) -> [Int] {
        tokens.filter { $0.rect.width > 0 && inside(CGPoint(x: $0.rect.midX, y: $0.rect.midY), points) }
            .map(\.index).sorted()
    }

    /// The circled words make one word or short phrase: all on one line, and few.
    static func isWordOrPhrase(_ indices: [Int], tokens: [(index: Int, rect: CGRect)]) -> Bool {
        guard let lo = indices.min(), let hi = indices.max(), hi - lo + 1 <= maxCircledWords else { return false }
        let rects = tokens.filter { indices.contains($0.index) }.map(\.rect)
        guard let first = rects.first else { return false }
        let lineH = rects.map(\.height).max() ?? first.height
        return rects.allSatisfy { abs($0.midY - first.midY) < lineH * 0.6 }
    }

    /// Words sitting right above the line: its height is at (or a little below) the
    /// bottom of the words — a stroke through the middle of the text is a highlight.
    static func underlined(_ points: [CGPoint], tokens: [(index: Int, rect: CGRect)]) -> [Int] {
        let xs = points.map(\.x)
        guard let minX = xs.min(), let maxX = xs.max() else { return [] }
        let y = points.map(\.y).sorted()[points.count / 2]
        var hits: [(index: Int, gap: CGFloat, height: CGFloat)] = []
        for t in tokens {
            let r = t.rect
            guard r.width > 0, r.height > 0 else { continue }
            let overlap = min(r.maxX, maxX) - max(r.minX, minX)
            guard overlap >= r.width * 0.5 else { continue }
            let gap = y - r.maxY
            guard gap >= -r.height * 0.3, gap <= r.height * 1.0 else { continue }
            hits.append((t.index, gap, r.height))
        }
        // The nearest line above only.
        guard let nearest = hits.map(\.gap).min() else { return [] }
        return hits.filter { $0.gap <= nearest + $0.height * 0.5 }.map(\.index).sorted()
    }

    /// Typical height of a line of text among these words.
    static func lineHeight(_ tokens: [(index: Int, rect: CGRect)]) -> CGFloat {
        let hs = tokens.map(\.rect.height).filter { $0 > 0 }.sorted()
        return hs.isEmpty ? 0 : hs[hs.count / 2]
    }

    /// Area enclosed by the stroke (closed from its end back to its start).
    private static func area(_ p: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
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
