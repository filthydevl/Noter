import PencilKit
import PDFKit

/// Carries scribbles between the PDF page and the Text view. There is one set of ink
/// per PDF page, kept in page points; the Text view shows each stroke moved next to
/// the same word it sits by on the page (and sized by how big that word is drawn), and
/// a stroke made in the Text view is moved back the same way. So a note written beside
/// a sentence is beside that sentence in both views.
enum TextInk {
    /// The page as displayed (rotation applied), in points: the space ink is stored in.
    static func pageSize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        return rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    static func center(_ stroke: PKStroke) -> CGPoint {
        let b = stroke.renderBounds
        return CGPoint(x: b.midX, y: b.midY)
    }

    /// The word of the book page nearest a point (page points). Being on the same
    /// line counts for more than being close sideways.
    static func nearestToken(to p: CGPoint, in lp: LogicalPage, pageSize: CGSize,
                             usable: (Int) -> Bool) -> Int? {
        var best: Int?
        var bestDistance = CGFloat.infinity
        for (i, t) in lp.tokens.enumerated() where usable(i) {
            let r = CGRect(x: t.rect.minX * pageSize.width, y: t.rect.minY * pageSize.height,
                           width: t.rect.width * pageSize.width, height: t.rect.height * pageSize.height)
            let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
            let d = dx + dy * 3
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    static func pageRect(_ token: Int, in lp: LogicalPage, pageSize: CGSize) -> CGRect {
        let r = lp.tokens[token].rect
        return CGRect(x: r.minX * pageSize.width, y: r.minY * pageSize.height,
                      width: r.width * pageSize.width, height: r.height * pageSize.height)
    }

    /// Moves a point from beside a word in one space to beside the same word in another.
    static func transform(from a: CGRect, to b: CGRect) -> CGAffineTransform {
        var scale = a.width > 1 ? b.width / a.width : 1
        if !scale.isFinite || scale <= 0 { scale = 1 }
        scale = min(max(scale, 0.25), 6)
        return CGAffineTransform(translationX: -a.midX, y: -a.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: b.midX, y: b.midY))
    }

    /// The column of text on the book page, left edge to right edge (page points).
    static func column(_ lp: LogicalPage, pageSize: CGSize) -> ClosedRange<CGFloat> {
        let lo = (lp.tokens.map(\.rect.minX).min() ?? 0) * pageSize.width
        let hi = (lp.tokens.map(\.rect.maxX).max() ?? 1) * pageSize.width
        return min(lo, hi)...max(lo, hi)
    }

    /// -1: in the left margin, 1: in the right margin, 0: over the text.
    private static func side(_ x: CGFloat, _ column: ClosedRange<CGFloat>, slack: CGFloat) -> Int {
        x < column.lowerBound - slack ? -1 : (x > column.upperBound + slack ? 1 : 0)
    }

    /// A move that takes `from` to `to`, scaling around it.
    private static func transform(from: CGPoint, to: CGPoint, scale raw: CGFloat) -> CGAffineTransform {
        var scale = raw
        if !scale.isFinite || scale <= 0 { scale = 1 }
        scale = min(max(scale, 0.25), 6)
        return CGAffineTransform(translationX: -from.x, y: -from.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: to.x, y: to.y))
    }

    /// Page ink → the Text view (or an exported text page). `textRect` gives a word's
    /// box where the text is laid out (nil: it isn't shown); `textColumn` is the column
    /// of text there, left edge to right edge.
    ///
    /// A stroke over the text goes beside the word it's nearest to. A stroke in a
    /// margin stays in that margin: beside the same line, the same distance out from
    /// the edge of the text (it used to follow the nearest word, which may sit at the
    /// other end of the line once the text wraps differently).
    static func toText(_ strokes: [PKStroke], lp: LogicalPage, pageSize: CGSize, textColumn: ClosedRange<CGFloat>,
                       textRect: (Int) -> CGRect?) -> [(shown: PKStroke, source: PKStroke)] {
        let pageColumn = column(lp, pageSize: pageSize)
        return strokes.compactMap { stroke in
            let c = center(stroke)
            let margin = side(c.x, pageColumn, slack: 2)
            if margin != 0, let placed = marginToText(stroke, c, margin, lp: lp, pageSize: pageSize,
                                                      pageColumn: pageColumn, textColumn: textColumn,
                                                      textRect: textRect) {
                return (placed, stroke)
            }
            guard var token = nearestToken(to: c, in: lp, pageSize: pageSize, usable: { _ in true }) else { return nil }
            // A word that isn't shown in the text (a stripped note number): a neighbour.
            var found = textRect(token)
            var step = 1
            while found == nil, step <= 6 {
                for candidate in [token + step, token - step] where candidate >= 0 && candidate < lp.tokens.count {
                    if let r = textRect(candidate) {
                        token = candidate
                        found = r
                        break
                    }
                }
                step += 1
            }
            guard let target = found else { return nil }
            var moved = stroke
            moved.transform = stroke.transform.concatenating(
                transform(from: pageRect(token, in: lp, pageSize: pageSize), to: target))
            return (moved, stroke)
        }
    }

    private static func marginToText(_ stroke: PKStroke, _ c: CGPoint, _ margin: Int, lp: LogicalPage,
                                     pageSize: CGSize, pageColumn: ClosedRange<CGFloat>,
                                     textColumn: ClosedRange<CGFloat>, textRect: (Int) -> CGRect?) -> PKStroke? {
        // The line of the page it's beside, and the word at that end of the line.
        let y = c.y / max(pageSize.height, 1)
        guard let line = lp.lines.min(by: { abs($0.rect.midY - y) < abs($1.rect.midY - y) }),
              !line.tokens.isEmpty else { return nil }
        let order = margin < 0 ? Array(line.tokens) : Array(line.tokens.reversed())
        guard let anchor = order.first(where: { textRect($0) != nil }), let target = textRect(anchor) else { return nil }
        let source = pageRect(anchor, in: lp, pageSize: pageSize)
        var moved = stroke
        moved.transform = stroke.transform.concatenating(transform(
            from: CGPoint(x: margin < 0 ? pageColumn.lowerBound : pageColumn.upperBound, y: source.midY),
            to: CGPoint(x: margin < 0 ? textColumn.lowerBound : textColumn.upperBound, y: target.midY),
            scale: source.width > 1 ? target.width / source.width : 1))
        return moved
    }

    /// A stroke drawn in the Text view → page ink. `tokenAt` finds the word nearest a
    /// point in the text; `lineTokens` the first and last word of the wrapped line at a
    /// height. A stroke in a margin lands in the page's margin on the same side, beside
    /// the line that word is on.
    static func toPage(_ stroke: PKStroke, lp: LogicalPage, pageSize: CGSize, textColumn: ClosedRange<CGFloat>,
                       tokenAt: (CGPoint) -> Int?, lineTokens: (CGFloat) -> (first: Int, last: Int)?,
                       textRect: (Int) -> CGRect?) -> PKStroke? {
        let c = center(stroke)
        let margin = side(c.x, textColumn, slack: 4)
        if margin != 0, let ends = lineTokens(c.y) {
            let anchor = margin < 0 ? ends.first : ends.last
            if anchor >= 0, anchor < lp.tokens.count, let from = textRect(anchor) {
                let to = pageRect(anchor, in: lp, pageSize: pageSize)
                let pageColumn = column(lp, pageSize: pageSize)
                var moved = stroke
                moved.transform = stroke.transform.concatenating(transform(
                    from: CGPoint(x: margin < 0 ? textColumn.lowerBound : textColumn.upperBound, y: from.midY),
                    to: CGPoint(x: margin < 0 ? pageColumn.lowerBound : pageColumn.upperBound, y: to.midY),
                    scale: from.width > 1 ? to.width / from.width : 1))
                return moved
            }
        }
        guard let token = tokenAt(c), let from = textRect(token) else { return nil }
        var moved = stroke
        moved.transform = stroke.transform.concatenating(
            transform(from: from, to: pageRect(token, in: lp, pageSize: pageSize)))
        return moved
    }

    /// Tells a stroke that's still as it was from one that was drawn, moved or cut.
    static func key(_ s: PKStroke) -> String {
        let b = s.renderBounds
        return "\(s.path.creationDate.timeIntervalSinceReferenceDate)|\(s.path.count)|"
            + "\(Int(b.minX.rounded()))|\(Int(b.minY.rounded()))|\(Int(b.width.rounded()))"
    }

    /// Whether a stroke of a PDF page belongs to this book page (the left or right half
    /// of a two-page spread).
    static func belongs(_ stroke: PKStroke, to lp: LogicalPage, pageSize: CGSize) -> Bool {
        guard lp.halfCount > 1 else { return true }
        let x = center(stroke).x / max(pageSize.width, 1)
        return lp.half == 0 ? x < lp.region.maxX : x >= lp.region.minX
    }
}
