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
            // Portrait pages are single book pages (two-column layouts are handled by
            // the reading order instead).
            guard page.aspect > 0.95 else { return nil }
            guard let g = findGutter(page) else { return page.aspect > 1.2 ? 0.5 : nil }
            // Clearly landscape scans of a book are spreads.
            if page.aspect > 1.2 { return g.x }
            // Borderline shapes need a clean, empty gutter with a full page of text on
            // each side — two pages, not two columns of one.
            let total = page.lines.reduce(0) { $0 + $1.k.count }
            let clean = g.crossing <= max(1, total / 50)
            return clean && g.leftShare > 0.2 && g.leftShare < 0.8 && bothSidesFull(page, gutter: g.x) ? g.x : nil
        }
    }

    /// Text on each side of the gutter runs down most of the page.
    private static func bothSidesFull(_ page: OCRPage, gutter x: CGFloat) -> Bool {
        let words = page.lines.flatMap { $0.k.map(\.r) }
        func extent(_ side: [CGRect]) -> CGFloat {
            guard let top = side.map(\.minY).min(), let bottom = side.map(\.maxY).max() else { return 0 }
            return bottom - top
        }
        return extent(words.filter { $0.maxX < x }) > 0.4 && extent(words.filter { $0.minX > x }) > 0.4
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
            var body = rows.enumerated().filter { !folioRows.contains($0.offset) }.map(\.element)
            // Running headers / footers and footnotes aren't part of the text you read.
            body = removePageFurniture(body)
            let headings = detectHeadings(body)
            return assemble(body, pdfIndex: pdfIndex, half: half, halfCount: halves, region: region, folio: folio,
                            headings: headings)
        }
    }

    static func meta(for page: OCRPage) -> PageMeta {
        func split(_ mode: LayoutMode) -> PageSplit {
            let pages = build(page, pdfIndex: page.page, mode: mode)
            return PageSplit(gutter: gutter(for: page, mode: mode), folios: pages.map(\.folio))
        }
        return PageMeta(auto: split(.auto), single: split(.single), spread: split(.spread))
    }

    /// Reading order for one book page: top to bottom, left to right — and when the
    /// text is set in two columns, the whole left column before the right one (a row
    /// spanning both columns, like a heading, starts a new band). Never interleaves
    /// lines from two columns.
    static func sortReadingOrder(_ rows: inout [Row]) {
        guard rows.count > 1 else { return }
        rows = visualLines(rows)
        guard let split = columnSplit(rows) else { return }
        var ordered: [Row] = []
        var left: [Row] = [], right: [Row] = []
        func flush() {
            ordered += left
            ordered += right
            left.removeAll()
            right.removeAll()
        }
        for row in rows {
            if row.rect.maxX <= split {
                left.append(row)
            } else if row.rect.minX >= split {
                right.append(row)
            } else {
                flush()
                ordered.append(row)
            }
        }
        flush()
        rows = ordered
    }

    /// Top to bottom; rows sharing a visual line, left to right. (A stable grouping —
    /// a plain pairwise comparison isn't transitive and can scramble lines.)
    private static func visualLines(_ rows: [Row]) -> [Row] {
        let byY = rows.sorted { $0.rect.midY < $1.rect.midY }
        var out: [Row] = []
        var group: [Row] = []
        for row in byY {
            if let anchor = group.first {
                let overlap = min(anchor.rect.maxY, row.rect.maxY) - max(anchor.rect.minY, row.rect.minY)
                if overlap > 0.5 * min(anchor.rect.height, row.rect.height) {
                    group.append(row)
                    continue
                }
                out += group.sorted { $0.rect.minX < $1.rect.minX }
                group.removeAll()
            }
            group.append(row)
        }
        out += group.sorted { $0.rect.minX < $1.rect.minX }
        return out
    }

    /// The x of a clean gap between two text columns, if the page has them.
    private static func columnSplit(_ rows: [Row]) -> CGFloat? {
        guard rows.count >= 8,
              let minX = rows.map(\.rect.minX).min(), let maxX = rows.map(\.rect.maxX).max() else { return nil }
        let width = maxX - minX
        guard width > 0.2 else { return nil }
        var best: (x: CGFloat, crossing: Int)?
        for step in 0...40 {
            let x = minX + width * (0.35 + 0.3 * CGFloat(step) / 40)
            let crossing = rows.filter { $0.rect.minX < x && $0.rect.maxX > x }.count
            if best == nil || crossing < best!.crossing
                || (crossing == best!.crossing && abs(x - (minX + width / 2)) < abs(best!.x - (minX + width / 2))) {
                best = (x, crossing)
            }
        }
        guard let b = best, b.crossing <= max(1, rows.count * 15 / 100) else { return nil }
        let left = rows.filter { $0.rect.maxX <= b.x }, right = rows.filter { $0.rect.minX >= b.x }
        func extent(_ side: [Row]) -> CGFloat {
            guard let top = side.map(\.rect.minY).min(), let bottom = side.map(\.rect.maxY).max() else { return 0 }
            return bottom - top
        }
        guard left.count >= 3, right.count >= 3, extent(left) > 0.3, extent(right) > 0.3 else { return nil }
        return b.x
    }

    // MARK: Page furniture

    /// Drops the running header / footer and the footnotes block at the bottom of the
    /// page, so the transcript (and read-aloud) is just the text.
    static func removePageFurniture(_ rows: [Row]) -> [Row] {
        guard rows.count >= 3 else { return rows }
        let heights = rows.map(\.rect.height).sorted()
        let medianH = max(heights[heights.count / 2], 0.002)
        let byY = rows.indices.sorted { rows[$0].rect.midY < rows[$1].rect.midY }
        var drop = Set<Int>()

        // Running header: a short, ordinary-sized line alone in the top margin.
        let top = byY[0], second = byY[1]
        let t = rows[top]
        if t.rect.midY < 0.09, t.tokens.count <= 10, t.rect.height < medianH * 1.15,
           rows[second].rect.minY - t.rect.maxY > medianH * 1.2 {
            drop.insert(top)
        }
        // Running footer: same at the bottom.
        let bottom = byY[byY.count - 1], above = byY[byY.count - 2]
        let b = rows[bottom]
        if b.rect.midY > 0.93, b.tokens.count <= 10, b.rect.height < medianH * 1.15,
           b.rect.minY - rows[above].rect.maxY > medianH * 1.2 {
            drop.insert(bottom)
        }

        // Footnotes: a block of smaller lines at the bottom, set apart by a gap or
        // starting with a note marker (1, *, †…).
        var block: [Int] = []
        var k = byY.count - 1
        if drop.contains(byY[k]) { k -= 1 }
        while k > 0, rows[byY[k]].rect.midY > 0.5, rows[byY[k]].rect.height < medianH * 0.86 {
            block.append(byY[k])
            k -= 1
        }
        if let first = block.last, k >= 0, block.count < rows.count / 2 + 1 {
            let gap = rows[first].rect.minY - rows[byY[k]].rect.maxY
            let marker = rows[first].tokens.first?.text.first.map { $0.isNumber || "*†‡§".contains($0) } ?? false
            if gap > medianH * 0.8 || marker { drop.formUnion(block) }
        }
        return rows.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    // MARK: Headings

    /// Chapter / section headings: rows set in larger type, short ALL-CAPS lines, or
    /// short centred lines set apart from the text — returned as row indices.
    static func detectHeadings(_ rows: [Row]) -> Set<Int> {
        guard rows.count >= 2 else { return [] }
        let heights = rows.map(\.rect.height).sorted()
        let medianH = max(heights[heights.count / 2], 0.002)
        let colMin = rows.map(\.rect.minX).min() ?? 0, colMax = rows.map(\.rect.maxX).max() ?? 1
        let colW = max(colMax - colMin, 0.01), colMid = (colMin + colMax) / 2
        var out = Set<Int>()
        for (i, row) in rows.enumerated() {
            let words = row.tokens.map(\.text)
            let joined = words.joined(separator: " ")
            guard words.count <= 14, joined.count >= 2 else { continue }
            let gapAbove = i == 0 ? 1 : row.rect.minY - rows[i - 1].rect.maxY
            let gapBelow = i == rows.count - 1 ? 1 : rows[i + 1].rect.minY - row.rect.maxY
            let letters = joined.filter(\.isLetter)
            let caps = letters.count >= 4 && Double(letters.filter(\.isUppercase).count) / Double(letters.count) > 0.8
            let endsSentence = joined.hasSuffix(".") && !joined.hasSuffix("..")
            let big = row.rect.height >= medianH * 1.3
            let capsLine = caps && words.count <= 10 && gapAbove > medianH * 0.8
            let centred = row.rect.width < colW * 0.6 && abs(row.rect.midX - colMid) < colW * 0.06
                && gapAbove > medianH * 1.2 && gapBelow > medianH * 0.9 && !endsSentence
            let chapter = joined.range(of: #"^(chapter|part|book|section)\s+([0-9ivxlc]+|[a-z]+)\b"#,
                                       options: [.regularExpression, .caseInsensitive]) != nil && words.count <= 8
            if big || capsLine || centred || chapter { out.insert(i) }
        }
        // A heading isn't half the page.
        return out.count > rows.count / 2 ? [] : out
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
                         region: CGRect, folio: Folio?, headings: Set<Int> = []) -> LogicalPage {
        var tokens: [LayoutToken] = []
        var lines: [LayoutLine] = []
        var ranges: [NSRange] = []
        var headingRanges: [NSRange] = []
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
                // Headings are paragraphs of their own.
                if headings.contains(ri) || headings.contains(ri - 1) { sep = "\n" }
                if joinWithoutSpace && sep != "\n" { sep = "" }
                text.append(sep)
            }
            joinWithoutSpace = false

            let lineStart = tokens.count
            let rowStart = text.length
            let rowMedianH = row.tokens.map(\.rect.height).sorted()[row.tokens.count / 2]
            var needsSpace = false
            for (ti, tok) in row.tokens.enumerated() {
                var display = noteMarkerStripped(tok, rowMedianHeight: rowMedianH, rowMidY: row.rect.midY)
                if needsSpace && !display.isEmpty { text.append(" ") }
                // "contin-" + "uing" → "continuing"
                if ti == row.tokens.count - 1, ri + 1 < rows.count, display.count > 2, !headings.contains(ri),
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
                if !display.isEmpty { needsSpace = true }
            }
            lines.append(LayoutLine(rect: row.rect, tokens: lineStart..<tokens.count))
            if headings.contains(ri), text.length > rowStart {
                headingRanges.append(NSRange(location: rowStart, length: text.length - rowStart))
            }
        }

        var index: [TokenKey: Int] = [:]
        for (i, t) in tokens.enumerated() { index[t.key] = i }

        return LogicalPage(
            pdfIndex: pdfIndex, half: half, halfCount: halfCount, region: region,
            tokens: tokens, lines: lines, text: text as String, tokenRanges: ranges,
            folio: folio, indexByKey: index, headingRanges: headingRanges)
    }

    /// Footnote reference numbers don't belong in the text: "war.12" → "war.", and a
    /// small raised "12" on its own is dropped entirely.
    static func noteMarkerStripped(_ tok: LayoutToken, rowMedianHeight: CGFloat, rowMidY: CGFloat) -> String {
        let t = tok.text
        if t.count <= 3, t.allSatisfy(\.isNumber), tok.rect.height < rowMedianHeight * 0.75,
           tok.rect.midY < rowMidY {
            return ""
        }
        if let r = t.range(of: #"(?<=\p{Ll}{2}[.,;:)\]”’"]?)\d{1,3}$"#, options: .regularExpression) {
            return String(t[..<r.lowerBound])
        }
        return t
    }
}
