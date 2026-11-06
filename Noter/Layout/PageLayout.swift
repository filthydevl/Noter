import Foundation
import CoreGraphics

/// Turns raw OCR of a PDF page into book pages:
///  1. decides whether the scan is a two-page spread and where the gutter is,
///  2. puts lines in reading order,
///  3. finds the printed page number (folio) and running header and drops them
///     from the text,
///  4. builds the transcript (paragraphs, de-hyphenation).
/// Pure functions — used both on the main thread and by the OCR worker.
enum PageLayout {
    struct Row {
        var rect: CGRect
        var tokens: [LayoutToken]
    }

    struct Gutter {
        let x: CGFloat
        let crossing: Int
        let leftShare: Double
    }

    // MARK: Spread detection

    static func gutter(for page: OCRPage, mode: LayoutMode) -> CGFloat? {
        switch mode {
        case .single:
            return nil
        case .spread:
            return findGutter(page)?.x ?? 0.5
        case .auto:
            guard page.aspect > 1.05 else { return nil }
            guard let g = findGutter(page) else { return page.aspect > 1.2 ? 0.5 : nil }
            // Clearly landscape scans of a book are spreads.
            if page.aspect > 1.2 { return g.x }
            // Borderline shapes need a clean, empty gutter with text on both sides.
            let total = page.lines.reduce(0) { $0 + $1.k.count }
            let clean = g.crossing <= max(1, total / 50)
            return clean && g.leftShare > 0.15 && g.leftShare < 0.85 ? g.x : nil
        }
    }

    /// Finds the vertical band in the middle of the page crossed by the fewest words
    /// (the gutter between two book pages), preferring the widest such band.
    static func findGutter(_ page: OCRPage) -> Gutter? {
        let rects = page.lines.flatMap { $0.k.map(\.r) }.filter { $0.width < 0.45 }
        guard !rects.isEmpty else { return nil }
        let lo: CGFloat = 0.3, hi: CGFloat = 0.7
        let steps = 160
        var counts = [Int](repeating: 0, count: steps + 1)
        for r in rects {
            let a = Int(((r.minX - lo) / (hi - lo) * CGFloat(steps)).rounded(.up))
            let b = Int(((r.maxX - lo) / (hi - lo) * CGFloat(steps)).rounded(.down))
            if b < 0 || a > steps || a > b { continue }
            for s in max(0, a)...min(steps, b) { counts[s] += 1 }
        }
        let minCount = counts.min() ?? 0
        let center = Double(steps) / 2
        var best: (start: Int, len: Int)?
        var i = 0
        while i <= steps {
            guard counts[i] == minCount else { i += 1; continue }
            var j = i
            while j + 1 <= steps, counts[j + 1] == minCount { j += 1 }
            let len = j - i + 1
            if let b = best {
                let mid = Double(i + j) / 2
                let bMid = Double(b.start) + Double(b.len - 1) / 2
                if len > b.len || (len == b.len && abs(mid - center) < abs(bMid - center)) { best = (i, len) }
            } else {
                best = (i, len)
            }
            i = j + 1
        }
        guard let b = best else { return nil }
        let midStep = CGFloat(b.start) + CGFloat(b.len - 1) / 2
        let x = lo + midStep / CGFloat(steps) * (hi - lo)
        let left = rects.filter { $0.midX < x }.count
        return Gutter(x: x, crossing: minCount, leftShare: Double(left) / Double(rects.count))
    }

    // MARK: Building book pages

    static func build(_ page: OCRPage, pdfIndex: Int, mode: LayoutMode) -> [LogicalPage] {
        let g = gutter(for: page, mode: mode)
        let halves = g == nil ? 1 : 2
        return (0..<halves).map { half in
            let region: CGRect
            if let g {
                region = half == 0
                    ? CGRect(x: 0, y: 0, width: g, height: 1)
                    : CGRect(x: g, y: 0, width: 1 - g, height: 1)
            } else {
                region = CGRect(x: 0, y: 0, width: 1, height: 1)
            }

            // A line Vision read straight across the gutter is split word by word.
            var rows: [Row] = []
            for (li, line) in page.lines.enumerated() {
                var toks: [LayoutToken] = []
                for (ti, t) in line.k.enumerated() {
                    if let g, (t.r.midX < g) != (half == 0) { continue }
                    toks.append(LayoutToken(key: TokenKey(line: li, token: ti), rect: t.r, text: t.t))
                }
                guard let first = toks.first else { continue }
                let rect = toks.dropFirst().reduce(first.rect) { $0.union($1.rect) }
                rows.append(Row(rect: rect, tokens: toks))
            }
            sortReadingOrder(&rows)
            let (folio, folioRows) = detectFolio(rows)
            let body = rows.enumerated().filter { !folioRows.contains($0.offset) }.map(\.element)
            return assemble(body, pdfIndex: pdfIndex, half: half, halfCount: halves, region: region, folio: folio)
        }
    }

    static func meta(for page: OCRPage) -> PageMeta {
        func split(_ mode: LayoutMode) -> PageSplit {
            let pages = build(page, pdfIndex: page.page, mode: mode)
            return PageSplit(gutter: gutter(for: page, mode: mode), folios: pages.map(\.folio))
        }
        return PageMeta(auto: split(.auto), single: split(.single), spread: split(.spread))
    }

    static func sortReadingOrder(_ rows: inout [Row]) {
        rows.sort { a, b in
            let overlap = min(a.rect.maxY, b.rect.maxY) - max(a.rect.minY, b.rect.minY)
            if overlap > 0.5 * min(a.rect.height, b.rect.height) { return a.rect.minX < b.rect.minX }
            return a.rect.midY < b.rect.midY
        }
    }

    // MARK: Page numbers

    /// Looks for a printed page number in the top/bottom margin: either a line that is
    /// only a number ("24", "– 24 –", "xii") or a running header with the number at one
    /// end separated by a wide gap ("24      THE TITLE").
    static func detectFolio(_ rows: [Row]) -> (Folio?, Set<Int>) {
        guard !rows.isEmpty else { return (nil, []) }
        var candidates: [Int] = Array(0..<min(2, rows.count))
        for i in max(0, rows.count - 2)..<rows.count where !candidates.contains(i) { candidates.append(i) }

        var folio: Folio?
        var excluded = Set<Int>()
        for i in candidates {
            let row = rows[i]
            let top = row.rect.midY < 0.13
            let bottom = row.rect.midY > 0.87
            guard top || bottom else { continue }
            let words = row.tokens.map(\.text)
            if let f = parseFolio(words.joined(separator: " ")) {
                folio = folio ?? f
                excluded.insert(i)
                continue
            }
            guard top, words.count >= 2, words.count <= 14 else { continue }
            let h = max(row.rect.height, 0.005)
            let t = row.tokens
            if let f = parseArabic(words[0]), t[1].rect.minX - t[0].rect.maxX > 1.5 * h {
                folio = folio ?? f
                excluded.insert(i)
            } else if let f = parseArabic(words[words.count - 1]),
                      t[t.count - 1].rect.minX - t[t.count - 2].rect.maxX > 1.5 * h {
                folio = folio ?? f
                excluded.insert(i)
            }
        }
        return (folio, excluded)
    }

    static func parseFolio(_ s: String) -> Folio? {
        let junk = CharacterSet(charactersIn: "-–—()[]{}.·•|*_").union(.whitespaces)
        let trimmed = s.trimmingCharacters(in: junk)
        if let n = parseArabic(trimmed) { return n }
        if let r = parseRoman(trimmed) { return Folio(value: r, roman: true) }
        return nil
    }

    static func parseArabic(_ s: String) -> Folio? {
        guard (1...4).contains(s.count), s.allSatisfy({ $0.isASCII && $0.isNumber }),
              let v = Int(s), v > 0 else { return nil }
        return Folio(value: v, roman: false)
    }

    static func parseRoman(_ s: String) -> Int? {
        let l = s.lowercased()
        guard (1...8).contains(l.count), l.allSatisfy({ "ivxlc".contains($0) }) else { return nil }
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100]
        var total = 0, prev = 0
        for ch in l.reversed() {
            let v = values[ch]!
            if v < prev { total -= v } else { total += v; prev = v }
        }
        guard total > 0, PageLabeler.roman(total) == l else { return nil }
        return total
    }

    // MARK: Transcript

    static func assemble(_ rows: [Row], pdfIndex: Int, half: Int, halfCount: Int,
                         region: CGRect, folio: Folio?) -> LogicalPage {
        var tokens: [LayoutToken] = []
        var lines: [LayoutLine] = []
        var ranges: [NSRange] = []
        let text = NSMutableString()

        let heights = rows.map(\.rect.height).sorted()
        let medianH = heights.isEmpty ? 0.01 : heights[heights.count / 2]
        var gaps: [CGFloat] = []
        if rows.count > 1 {
            for i in 1..<rows.count {
                let gap = rows[i].rect.minY - rows[i - 1].rect.maxY
                if gap > 0 { gaps.append(gap) }
            }
        }
        gaps.sort()
        let medianGap = gaps.isEmpty ? medianH * 0.4 : gaps[gaps.count / 2]
        let colMinX = rows.map(\.rect.minX).min() ?? 0
        let colMaxX = rows.map(\.rect.maxX).max() ?? 1
        let colW = max(colMaxX - colMinX, 0.01)

        var joinWithoutSpace = false
        for (ri, row) in rows.enumerated() {
            if ri > 0 {
                let prev = rows[ri - 1]
                let gap = row.rect.minY - prev.rect.maxY
                var sep = " "
                if gap > -0.3 * medianH { // not on the same visual row
                    let bigGap = gap > medianGap * 1.8 + medianH * 0.3
                    let indented = row.rect.minX - colMinX > medianH * 1.2 && prev.rect.minX - colMinX < medianH * 0.6
                    let shortPrevious = colMaxX - prev.rect.maxX > colW * 0.2
                    if bigGap || indented || shortPrevious { sep = "\n" }
                }
                if joinWithoutSpace { sep = "" }
                text.append(sep)
            }
            joinWithoutSpace = false

            let lineStart = tokens.count
            for (ti, tok) in row.tokens.enumerated() {
                if ti > 0 { text.append(" ") }
                var display = tok.text
                // "contin-" + "uing" → "continuing"
                if ti == row.tokens.count - 1, ri + 1 < rows.count, display.count > 2,
                   display.hasSuffix("-") || display.hasSuffix("¬"),
                   display.dropLast().last?.isLetter == true,
                   let next = rows[ri + 1].tokens.first?.text.first, next.isLowercase {
                    display.removeLast()
                    joinWithoutSpace = true
                }
                let loc = text.length
                text.append(display)
                ranges.append(NSRange(location: loc, length: (display as NSString).length))
                tokens.append(tok)
            }
            lines.append(LayoutLine(rect: row.rect, tokens: lineStart..<tokens.count))
        }

        var index: [TokenKey: Int] = [:]
        for (i, t) in tokens.enumerated() { index[t.key] = i }

        return LogicalPage(
            pdfIndex: pdfIndex, half: half, halfCount: halfCount, region: region,
            tokens: tokens, lines: lines, text: text as String, tokenRanges: ranges,
            folio: folio, indexByKey: index)
    }
}
