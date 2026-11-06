import Foundation
import CoreGraphics

struct LayoutToken {
    let key: TokenKey
    let rect: CGRect
    let text: String
}

struct LayoutLine {
    let rect: CGRect
    /// Indices into `LogicalPage.tokens`.
    let tokens: Range<Int>
}

/// One *book* page: a whole PDF page, or the left/right half of a two-page spread.
/// Tokens are in reading order; `text` is the transcript (headers / page numbers removed,
/// end-of-line hyphenation joined) and `tokenRanges` maps every token into it.
struct LogicalPage {
    let pdfIndex: Int
    let half: Int
    let halfCount: Int
    /// Area of the PDF page this book page occupies (normalized).
    let region: CGRect
    let tokens: [LayoutToken]
    let lines: [LayoutLine]
    let text: String
    let tokenRanges: [NSRange]
    let folio: Folio?
    let indexByKey: [TokenKey: Int]

    var slot: SlotKey { SlotKey(pdfIndex: pdfIndex, half: half) }

    // MARK: Lookups

    /// Token at (or just before) a UTF-16 offset in `text`.
    func tokenIndex(atUTF16 offset: Int) -> Int? {
        guard !tokenRanges.isEmpty else { return nil }
        var lo = 0, hi = tokenRanges.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if tokenRanges[mid].location <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func lineIndex(forToken t: Int) -> Int? {
        var lo = 0, hi = lines.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = lines[mid].tokens
            if t < r.lowerBound { hi = mid - 1 } else if t >= r.upperBound { lo = mid + 1 } else { return mid }
        }
        return nil
    }

    /// The text line under a normalized page point, tolerant of a pen that is a bit
    /// above or below the line.
    func nearestLine(to p: CGPoint) -> Int? {
        var best: Int?
        var bestDistance = CGFloat.infinity
        for (i, line) in lines.enumerated() {
            let r = line.rect
            let pad = max(r.height * 0.45, 0.004)
            guard p.y >= r.minY - pad, p.y <= r.maxY + pad,
                  p.x >= r.minX - 0.03, p.x <= r.maxX + 0.03 else { continue }
            let d = abs(p.y - r.midY)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    func nearestToken(inLine li: Int, x: CGFloat) -> Int {
        let range = lines[li].tokens
        var best = range.lowerBound
        var bestDistance = CGFloat.infinity
        for i in range {
            let r = tokens[i].rect
            if x >= r.minX && x <= r.maxX { return i }
            let d = min(abs(x - r.minX), abs(x - r.maxX))
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    /// Token range of an existing highlight on this book page (nil if it isn't on it).
    func range(of h: Highlight) -> ClosedRange<Int>? {
        guard h.page == pdfIndex else { return nil }
        let idx = h.tokenKeys.compactMap { indexByKey[$0] }
        guard let a = idx.min(), let b = idx.max() else { return nil }
        return a...b
    }

    // MARK: Building highlights

    func textRange(for r: ClosedRange<Int>) -> NSRange {
        let a = tokenRanges[r.lowerBound], b = tokenRanges[r.upperBound]
        return NSRange(location: a.location, length: NSMaxRange(b) - a.location)
    }

    func string(for r: ClosedRange<Int>) -> String {
        (text as NSString).substring(with: textRange(for: r))
    }

    /// One rect per text line covered by the token range (normalized page coords).
    func lineRects(for r: ClosedRange<Int>) -> [CGRect] {
        var out: [CGRect] = []
        for line in lines where line.tokens.lowerBound <= r.upperBound && line.tokens.upperBound - 1 >= r.lowerBound {
            let a = max(r.lowerBound, line.tokens.lowerBound)
            let b = min(r.upperBound, line.tokens.upperBound - 1)
            var u = tokens[a].rect
            for i in a...b { u = u.union(tokens[i].rect) }
            out.append(CGRect(x: u.minX, y: line.rect.minY, width: u.width, height: line.rect.height))
        }
        return out
    }

    func spans(for r: ClosedRange<Int>) -> [TokenSpan] {
        var spans: [TokenSpan] = []
        for i in r {
            let k = tokens[i].key
            if var last = spans.last, last.line == k.line, last.end + 1 == k.token {
                last.end = k.token
                spans[spans.count - 1] = last
            } else {
                spans.append(TokenSpan(line: k.line, start: k.token, end: k.token))
            }
        }
        return spans
    }
}

// MARK: - Pen → words

struct PageSelection {
    let page: LogicalPage
    let range: ClosedRange<Int>
}

enum PageHitTester {
    /// Maps one normalized pen point on a PDF page to a word. `half` locks the stroke
    /// to the book page it started on so a sloppy stroke never jumps across the gutter.
    static func hit(_ n: CGPoint, in pages: [LogicalPage], half: inout Int?) -> StrokeHit? {
        guard !pages.isEmpty, n.x >= -0.02, n.x <= 1.02, n.y >= -0.02, n.y <= 1.02 else { return nil }
        let idx = pages.firstIndex { n.x >= $0.region.minX && n.x < $0.region.maxX }
            ?? (n.x < 0.5 ? 0 : pages.count - 1)
        if let h = half, h != idx { return nil }
        let lp = pages[idx]
        guard let li = lp.nearestLine(to: n) else { return nil }
        half = idx
        return StrokeHit(line: li, token: lp.nearestToken(inLine: li, x: n.x), x: n.x)
    }

    /// What a finished pen stroke should highlight.
    static func selection(for points: [CGPoint], in pages: [LogicalPage]) -> PageSelection? {
        var half: Int?
        let hits = points.compactMap { hit($0, in: pages, half: &half) }
        if let h = half, let r = Snapper.range(for: hits, referenceWidth: pages[h].region.width) {
            return PageSelection(page: pages[h], range: r)
        }
        return marginSelection(points, in: pages)
    }

    /// A mostly vertical stroke in the margin highlights the lines next to it.
    static func marginSelection(_ points: [CGPoint], in pages: [LogicalPage]) -> PageSelection? {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let w = maxX - minX, h = maxY - minY
        guard h > 0.02, h > w * 2.5 else { return nil }
        let midX = (minX + maxX) / 2
        let idx = pages.firstIndex { midX >= $0.region.minX && midX < $0.region.maxX }
            ?? (midX < 0.5 ? 0 : pages.count - 1)
        let lp = pages[idx]
        let covered = lp.lines.filter { $0.rect.midY >= minY && $0.rect.midY <= maxY && !$0.tokens.isEmpty }
        guard let first = covered.first, let last = covered.last else { return nil }
        return PageSelection(page: lp, range: first.tokens.lowerBound...(last.tokens.upperBound - 1))
    }
}
