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

    /// Page ink → the Text view (or an exported text page). `textRect` gives a word's
    /// box where the text is laid out (nil: it isn't shown).
    static func toText(_ strokes: [PKStroke], lp: LogicalPage, pageSize: CGSize,
                       textRect: (Int) -> CGRect?) -> [(shown: PKStroke, source: PKStroke)] {
        strokes.compactMap { stroke in
            guard var token = nearestToken(to: center(stroke), in: lp, pageSize: pageSize,
                                           usable: { _ in true }) else { return nil }
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

    /// A stroke drawn in the Text view → page ink. `tokenAt` finds the word nearest a
    /// point in the text.
    static func toPage(_ stroke: PKStroke, lp: LogicalPage, pageSize: CGSize, tokenAt: (CGPoint) -> Int?,
                       textRect: (Int) -> CGRect?) -> PKStroke? {
        guard let token = tokenAt(center(stroke)), let from = textRect(token) else { return nil }
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
