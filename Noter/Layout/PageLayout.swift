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
        /// Straightened (tilt removed) — used to work out lines and reading order.
        var rect: CGRect
        var tokens: [LayoutToken]
        /// Where the row really is on the page (for highlighting and hit testing).
        var pageRect: CGRect
        /// The page's tilt (see `estimateShear`).
        var shear: CGFloat = 0

        /// The row's middle line at `x`, in page coordinates (follows the tilt).
        func midY(atX x: CGFloat) -> CGFloat { rect.midY + shear * (x - 0.5) }
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
        let shear = estimateShear(page)
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
                let pageRect = toks.dropFirst().reduce(first.rect) { $0.union($1.rect) }
                let straight = toks.dropFirst().reduce(straighten(first.rect, shear)) { $0.union(straighten($1.rect, shear)) }
                rows.append(Row(rect: straight, tokens: toks, pageRect: pageRect, shear: shear))
            }
            sortReadingOrder(&rows)
            let found = detectFolio(rows)
            var body = rows.enumerated().filter { !found.rows.contains($0.offset) }.map(\.element)
            // Running headers / footers aren't part of the text you read; footnotes go
            // at the end, marked, so read-aloud can leave them out.
            let furniture = removePageFurniture(body)
            body = furniture.rows
            let headings = detectHeadings(body)
            return assemble(body + furniture.notes, pdfIndex: pdfIndex, half: half, halfCount: halves,
                            region: region, folio: found.folio, headings: headings,
                            runningHeader: found.header ?? furniture.header,
                            notesFrom: furniture.notes.isEmpty ? nil : body.count)
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
                // Pieces of one visual line sit side by side; rows that overlap
                // sideways are different lines, however close vertically.
                let sideBySide = group.allSatisfy { g in
                    g.rect.maxX <= row.rect.minX + g.rect.height || row.rect.maxX <= g.rect.minX + g.rect.height
                }
                if sideBySide, overlap > 0.5 * min(anchor.rect.height, row.rect.height) {
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

    // MARK: Tilted scans

    /// How much the text slopes on a tilted scan, as Δy per Δx in normalized page
    /// coordinates — the median slope of word positions along each line (Vision's word
    /// boxes follow the tilt). 0 for straight pages.
    static func estimateShear(_ page: OCRPage) -> CGFloat {
        var slopes: [CGFloat] = []
        for line in page.lines where line.k.count >= 4 {
            let xs = line.k.map(\.r.midX), ys = line.k.map(\.r.midY)
            let n = CGFloat(xs.count)
            let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
            var num: CGFloat = 0, den: CGFloat = 0
            for i in xs.indices {
                num += (xs[i] - mx) * (ys[i] - my)
                den += (xs[i] - mx) * (xs[i] - mx)
            }
            guard den > 0.002 else { continue } // too short to tell
            slopes.append(num / den)
        }
        guard slopes.count >= 3 else { return 0 }
        slopes.sort()
        let s = slopes[slopes.count / 2]
        return abs(s) < 0.002 ? 0 : min(max(s, -0.15), 0.15)
    }

    /// Removes the tilt (a shear about the page's middle) so a line's pieces line up.
    static func straighten(_ r: CGRect, _ shear: CGFloat) -> CGRect {
        shear == 0 ? r : r.offsetBy(dx: 0, dy: -shear * (r.midX - 0.5))
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

    /// Drops the running header / footer, so the transcript (and read-aloud) is just the
    /// text, and sets the footnotes block at the bottom of the page apart (`notes`).
    /// Returns the running header's text too, to show next to the page number instead.
    static func removePageFurniture(_ rows: [Row]) -> (rows: [Row], header: String?, notes: [Row]) {
        guard rows.count >= 3 else { return (rows, nil, []) }
        let heights = rows.map(\.rect.height).sorted()
        let medianH = max(heights[heights.count / 2], 0.002)
        let byY = rows.indices.sorted { rows[$0].rect.midY < rows[$1].rect.midY }
        var gaps: [CGFloat] = []
        for k in 1..<byY.count {
            let g = rows[byY[k]].rect.minY - rows[byY[k - 1]].rect.maxY
            if g > 0 { gaps.append(g) }
        }
        gaps.sort()
        let typicalGap = gaps.isEmpty ? medianH * 0.4 : gaps[gaps.count / 2]
        var drop = Set<Int>()
        var header: String?

        let tokenHeights = rows.flatMap { $0.tokens.map(\.rect.height) }.sorted()
        let bodyH = max(tokenHeights[tokenHeights.count / 2], 0.002)
        let colMin = rows.map(\.rect.minX).min() ?? 0, colMax = rows.map(\.rect.maxX).max() ?? 1
        let colW = max(colMax - colMin, 0.01)

        /// The page's top / bottom line (all its pieces) is a running header / footer if
        /// it sits in the margin, is short, isn't set larger than the text (that would be
        /// a heading), isn't a sentence, and stands apart: a bigger gap than between
        /// lines, ALL CAPS / small caps, or not running the full width.
        func furniture(top: Bool) -> (rows: [Int], text: String)? {
            let band = PageLayout.edgeBand(rows, top: top)
            guard !band.isEmpty, band.count < rows.count else { return nil }
            let tokens = band.flatMap { rows[$0].tokens }.sorted { $0.rect.minX < $1.rect.minX }
            let text = tokens.map(\.text).joined(separator: " ")
            let minY = band.map { rows[$0].rect.minY }.min() ?? 0
            let maxY = band.map { rows[$0].rect.maxY }.max() ?? 1
            let midY = (minY + maxY) / 2
            guard top ? midY < 0.16 : midY > 0.86 else { return nil }
            let others = rows.indices.filter { !band.contains($0) }
            let gap = top
                ? (others.map { rows[$0].rect.minY }.min() ?? 1) - maxY
                : minY - (others.map { rows[$0].rect.maxY }.max() ?? 0)
            let heights = tokens.map(\.rect.height).sorted()
            let lineH = heights[heights.count / 2]
            let width = (tokens.map(\.rect.maxX).max() ?? 0) - (tokens.map(\.rect.minX).min() ?? 0)
            let letters = text.filter(\.isLetter)
            let caps = letters.count >= 3
                && Double(letters.filter(\.isUppercase).count) / Double(letters.count) > 0.8
            let sentence = text.hasSuffix(".") && !text.hasSuffix("..")
            let chapter = text.range(of: #"^(chapter|part|book|section)\b"#,
                                     options: [.regularExpression, .caseInsensitive]) != nil
            guard tokens.count <= 12, lineH < bodyH * 1.25, !sentence, !chapter else { return nil }
            guard gap > typicalGap * 1.3 || caps || width < colW * 0.7 else { return nil }
            return (band, text)
        }

        if let h = furniture(top: true) {
            drop.formUnion(h.rows)
            header = h.text
        }
        if let f = furniture(top: false) { drop.formUnion(f.rows) }

        // Extraneous lines at the foot (and head) of the page: DOIs, links, copyright,
        // publisher / journal / download stamps, ISSN / ISBN, licences.
        func rowText(_ i: Int) -> String { rows[i].tokens.map(\.text).joined(separator: " ") }
        func rowH(_ i: Int) -> CGFloat {
            let hs = rows[i].tokens.map(\.rect.height).sorted()
            return hs.isEmpty ? rows[i].rect.height : hs[hs.count / 2]
        }
        func gapAbove(_ pos: Int) -> CGFloat {
            pos == 0 ? .infinity : rows[byY[pos]].rect.minY - rows[byY[pos - 1]].rect.maxY
        }
        for (pos, i) in byY.enumerated().reversed() where !drop.contains(i) {
            let r = rows[i].rect
            guard r.midY > 0.72 else { break }
            let t = rowText(i)
            let strong = Self.matches(Self.strongExtraneous, t)
            let weak = Self.matches(Self.weakExtraneous, t)
            let apart = rowH(i) < bodyH * 0.95 || gapAbove(pos) > typicalGap * 1.3 || r.width < colW * 0.7
                || pos == byY.count - 1 || drop.contains(byY[min(pos + 1, byY.count - 1)])
            if strong || (weak && apart) { drop.insert(i) }
        }
        for i in byY.prefix(4) where !drop.contains(i) && rows[i].rect.midY < 0.12 {
            if Self.matches(Self.strongExtraneous, rowText(i)) { drop.insert(i) }
        }

        // Footnotes (Chicago-style notes and the like): a block of lines at the bottom
        // of the page, each note starting with its number ("1", "12.", "¹", "*", "†"…),
        // that is
        // * set in smaller type, set apart by a gap or starting with a note number
        //   (a line the OCR measured a touch taller doesn't break the block), or
        // * same-size but after a clear gap, or two or more numbered notes in a row in
        //   slightly smaller type.
        let kept = byY.filter { !drop.contains($0) }
        var notes = Set<Int>()
        func startsWithMarker(_ i: Int) -> Bool {
            Self.startsWithNoteMarker(rows[i].tokens.first?.text ?? "")
        }
        var block: [Int] = []
        var k = kept.count - 1
        while k > 0, rows[kept[k]].rect.midY > 0.5 {
            let h = rowH(kept[k])
            let small = h < bodyH * 0.92
            let numberedNote = !block.isEmpty && startsWithMarker(kept[k]) && h < bodyH * 1.0
            guard small || numberedNote else { break }
            block.append(kept[k])
            k -= 1
        }
        func gapBefore(_ i: Int, below j: Int) -> CGFloat { rows[i].rect.minY - rows[j].rect.maxY }
        if let first = block.last, k >= 0, block.count < rows.count / 2 + 1 {
            let gap = gapBefore(first, below: kept[k])
            if gap > medianH * 0.8 || gap > typicalGap * 1.4 || startsWithMarker(first) { notes.formUnion(block) }
        }
        // Same-size footnotes after a clear break, or a run of numbered notes.
        if notes.isEmpty {
            let lower = kept.filter { rows[$0].rect.midY > 0.55 }
            for (n, i) in lower.enumerated() {
                guard let pos = kept.firstIndex(of: i), pos > 0 else { continue }
                let below = Array(lower[n...])
                guard below.count <= max(rows.count * 2 / 5, 1), startsWithMarker(i) else { continue }
                let numbered = below.filter(startsWithMarker).count
                let apart = gapBefore(i, below: kept[pos - 1]) > typicalGap * 1.8
                    && below.allSatisfy({ rowH($0) <= bodyH * 1.02 })
                let run = numbered >= 2 && below.allSatisfy({ rowH($0) <= bodyH * 0.97 })
                guard apart || run else { continue }
                notes.formUnion(below)
                break
            }
        }
        // Long notes that fill most of the page (the text above them is only a few
        // lines, so "smaller than the page's usual type" can't see them): from a line
        // that starts with a note number down, everything is set smaller than the
        // lines above it.
        if notes.isEmpty, kept.count >= 4 {
            func median(_ v: [CGFloat]) -> CGFloat {
                let s = v.sorted()
                return s.isEmpty ? 0 : s[s.count / 2]
            }
            for pos in 1..<kept.count where startsWithMarker(kept[pos]) && rows[kept[pos]].rect.midY > 0.15 {
                let above = kept[..<pos].map(rowH), below = kept[pos...].map(rowH)
                let aboveH = median(above)
                guard aboveH > 0, below.count >= 2, median(below) <= aboveH * 0.9 else { continue }
                let small = below.filter { $0 <= aboveH * 0.95 }.count
                guard Double(small) >= Double(below.count) * 0.85 else { continue }
                notes.formUnion(kept[pos...])
                break
            }
        }
        let body = rows.enumerated().filter { !drop.contains($0.offset) && !notes.contains($0.offset) }.map(\.element)
        let noteRows = rows.enumerated().filter { notes.contains($0.offset) }.map(\.element)
        return (body, header, noteRows)
    }

    /// A footnote starts with its number: "1", "12.", "3)", "¹", "*", "†" — on its own
    /// or glued to the first word ("1See", "¹See").
    static func startsWithNoteMarker(_ first: String) -> Bool {
        if first.range(of: #"^(\d{1,3}|[⁰¹²³⁴⁵⁶⁷⁸⁹]{1,3}|[*†‡§¶]+)[.)]?$"#, options: .regularExpression) != nil {
            return true
        }
        return first.range(of: #"^(\d{1,3}|[⁰¹²³⁴⁵⁶⁷⁸⁹]{1,3})[.)]?[A-Z“"][a-z]"#, options: .regularExpression) != nil
    }

    // MARK: Headings

    /// Chapter / section headings, as row indices. A heading must
    ///  * be short (≤ 12 words) and start with a capital or a number,
    ///  * not read like part of a sentence: no "." "," ";" ":" at the end, no lowercase
    ///    continuation on the next line, not continuing an unfinished previous line,
    ///  * be set apart from the text by extra space,
    ///  * and look like a heading: larger type (judged from word heights, which one
    ///    tall character can't inflate), ALL CAPS, centred (the same margin on both
    ///    sides, wherever on the page it is), "Chapter N", or the title of one source
    ///    in a collection of primary sources ("Document 3: …", "Source 2", "Excerpt
    ///    from …").
    /// A heading that wraps onto more lines in the same style keeps them all.
    static func detectHeadings(_ rows: [Row]) -> Set<Int> {
        guard rows.count >= 3 else { return [] }
        func median(_ v: [CGFloat]) -> CGFloat {
            let s = v.sorted()
            return s.isEmpty ? 0 : s[s.count / 2]
        }
        let bodyH = max(median(rows.flatMap { $0.tokens.map(\.rect.height) }), 0.002)
        let rowH = rows.map { median($0.tokens.map(\.rect.height)) }
        var gaps: [CGFloat] = []
        for i in 1..<rows.count {
            let g = rows[i].rect.minY - rows[i - 1].rect.maxY
            if g > 0 { gaps.append(g) }
        }
        let typicalGap = max(gaps.isEmpty ? bodyH * 0.4 : median(gaps), bodyH * 0.15)
        let colMin = rows.map(\.rect.minX).min() ?? 0, colMax = rows.map(\.rect.maxX).max() ?? 1
        let colW = max(colMax - colMin, 0.01), colMid = (colMin + colMax) / 2

        func text(_ i: Int) -> String { rows[i].tokens.map(\.text).joined(separator: " ") }
        func gapAbove(_ i: Int) -> CGFloat { i == 0 ? .infinity : rows[i].rect.minY - rows[i - 1].rect.maxY }
        func gapBelow(_ i: Int) -> CGFloat {
            i == rows.count - 1 ? .infinity : rows[i + 1].rect.minY - rows[i].rect.maxY
        }
        func isCaps(_ t: String) -> Bool {
            let letters = t.filter(\.isLetter)
            return letters.count >= 4 && Double(letters.filter(\.isUppercase).count) / Double(letters.count) > 0.85
        }
        let chapterPattern = #"^(chapter|part|book|section)\s+([0-9ivxlc]+|[a-z]+)\b"#
        let sourcePattern = #"^((primary\s+)?(document|doc\.|source|reading|selection|exhibit|appendix)\s*([0-9]+[a-z]?|[ivxlc]+|[a-z])\b|(an\s+)?(excerpts?|extracts?)\s+from\b)"#
        /// Same margin left and right, clearly in from both: set in the middle.
        func isCentred(_ i: Int) -> Bool {
            let left = rows[i].rect.minX - colMin, right = colMax - rows[i].rect.maxX
            return rows[i].rect.width < colW * 0.8 && left > colW * 0.07 && right > colW * 0.07
                && abs(left - right) < max(colW * 0.08, (left + right) * 0.25)
        }

        var out = Set<Int>()
        var style: [Int: String] = [:] // why each heading qualified, for wrapped lines
        for i in rows.indices {
            let t = text(i)
            let words = rows[i].tokens.count
            let source = t.range(of: sourcePattern, options: [.regularExpression, .caseInsensitive]) != nil
            guard (1...(source ? 18 : 12)).contains(words),
                  let firstLetter = t.first(where: { $0.isLetter || $0.isNumber }),
                  firstLetter.isUppercase || firstLetter.isNumber else { continue }
            // A long title wraps mid-phrase ("…Enlightenment," / "Reform, and the…"): a
            // centred line in larger type, set apart above, is a title's first line
            // even when it ends in a comma or colon.
            let titleStart = isCentred(i) && rowH[i] >= bodyH * 1.1 && gapAbove(i) > typicalGap * 1.7
            // Reads like part of a sentence ("Document 3:" is fine).
            if let last = t.last, ".,;:".contains(last), !t.hasSuffix("..."), !(source && last == ":"),
               !(titleStart && last != ".") { continue }
            if i + 1 < rows.count, gapBelow(i) < typicalGap * 1.6, !titleStart,
               let next = text(i + 1).first(where: \.isLetter), next.isLowercase { continue }
            if i > 0, gapAbove(i) < typicalGap * 1.6, let prevLast = text(i - 1).last,
               prevLast.isLetter || prevLast == "," || prevLast == "-" { continue }

            let spacedAbove = gapAbove(i) > typicalGap * 1.7
            let spacedBelow = gapBelow(i) > typicalGap * 1.3
            let big = rowH[i] >= bodyH * 1.35
            let caps = isCaps(t) && words <= 10
            let centred = isCentred(i) && abs(rows[i].rect.midX - colMid) < colW * 0.1
            let chapter = t.range(of: chapterPattern, options: [.regularExpression, .caseInsensitive]) != nil
                && words <= 8

            if (big || chapter) && (spacedAbove || spacedBelow) {
                out.insert(i)
                style[i] = big ? "big" : "chapter"
            } else if source && (spacedAbove || spacedBelow || centred || caps) {
                out.insert(i)
                style[i] = "source"
            } else if caps && spacedAbove && spacedBelow {
                out.insert(i)
                style[i] = "caps"
            } else if centred && words <= 12 && (spacedAbove || spacedBelow || i == 0) {
                out.insert(i)
                style[i] = "centred"
            }
        }

        // More lines of a wrapped heading: same style, tight below the one before.
        for i in out.sorted() {
            var k = i
            while k + 1 < rows.count, !out.contains(k + 1), k - i < 3 {
                let j = k + 1
                let t = text(j)
                guard rows[j].tokens.count <= 14, gapBelow(k) < typicalGap * 1.6 else { break }
                let sameSize = abs(rowH[j] - rowH[k]) < rowH[k] * 0.12
                let continues: Bool
                switch style[i] {
                case "big": continues = sameSize && rowH[j] >= bodyH * 1.35
                case "caps": continues = isCaps(t)
                case "centred": continues = sameSize && (isCentred(j) || rowH[j] >= bodyH * 1.1)
                case "source": continues = sameSize && (isCentred(j) || t.count < 70)
                    && !(t.last.map { ".".contains($0) } ?? false)
                default: continues = false
                }
                guard continues else { break }
                out.insert(j)
                style[j] = style[i]
                k = j
            }
        }
        // Headings are rare: if a lot of lines qualify, the page is just unusual.
        return out.count > max(2, rows.count / 4) ? [] : out
    }

    // MARK: Page numbers

    /// Looks for a printed page number in the top/bottom margin: either a line that is
    /// only a number ("24", "– 24 –", "xii") or a running header with the number at one
    /// end separated by a wide gap ("24      THE TITLE").
    /// The rows on the page's top (or bottom) visual line. Vision often reads one header
    /// line — "12", "JANE DOE", "WOMEN AND WAR" — as separate pieces.
    static func edgeBand(_ rows: [Row], top: Bool) -> [Int] {
        guard !rows.isEmpty else { return [] }
        let byY = rows.indices.sorted {
            top ? rows[$0].rect.midY < rows[$1].rect.midY : rows[$0].rect.midY > rows[$1].rect.midY
        }
        let anchor = rows[byY[0]].rect
        return byY.filter { i in
            let r = rows[i].rect
            let overlap = min(anchor.maxY, r.maxY) - max(anchor.minY, r.minY)
            return overlap > 0.4 * min(anchor.height, r.height)
        }
    }

    /// A page number at the end of a header line: arabic, or lowercase roman ("xii")
    /// — not a capital "I" that starts a sentence.
    private static func edgeFolio(_ word: String) -> Folio? {
        let junk = CharacterSet(charactersIn: "-–—()[]{}.,·•|*_").union(.whitespaces)
        let t = word.trimmingCharacters(in: junk)
        if let f = parseArabic(t) { return f }
        if t == t.lowercased(), let r = parseRoman(t) { return Folio(value: r, roman: true) }
        return nil
    }

    /// Finds the printed page number (folio) on the page's top or bottom line — on its
    /// own ("24", "– 24 –") or at either end of a running header ("24   JANE DOE",
    /// "WOMEN AND WAR   25") — and returns the rows of that whole line (they're not
    /// read), plus the header's words for the page label.
    static func detectFolio(_ rows: [Row]) -> (folio: Folio?, rows: Set<Int>, header: String?) {
        guard !rows.isEmpty else { return (nil, [], nil) }
        let colMin = rows.map(\.rect.minX).min() ?? 0, colMax = rows.map(\.rect.maxX).max() ?? 1
        let colW = max(colMax - colMin, 0.01)
        var folio: Folio?
        var excluded = Set<Int>()
        var header: String?
        for top in [true, false] {
            let band = edgeBand(rows, top: top)
            guard !band.isEmpty, !band.contains(where: excluded.contains) else { continue }
            let midY = band.map { rows[$0].rect.midY }.reduce(0, +) / CGFloat(band.count)
            guard top ? midY < 0.16 : midY > 0.84 else { continue }
            let tokens = band.flatMap { rows[$0].tokens }.sorted { $0.rect.minX < $1.rect.minX }
            guard !tokens.isEmpty, tokens.count <= 16 else { continue }
            let words = tokens.map(\.text)
            let heights = tokens.map(\.rect.height).sorted()
            let h = max(heights[heights.count / 2], 0.005)
            let width = (tokens.map(\.rect.maxX).max() ?? 0) - (tokens.map(\.rect.minX).min() ?? 0)
            // A body line runs the full width; a header line is shorter or has a gap.
            let narrow = width < colW * 0.85
            var found: Folio?
            var numberAt: Int?
            if let f = parseFolio(words.joined(separator: " ")) {
                found = f
            } else if words.count >= 2 {
                let n = words.count
                if let f = edgeFolio(words[0]), narrow || tokens[1].rect.minX - tokens[0].rect.maxX > 0.8 * h {
                    found = f
                    numberAt = 0
                } else if let f = edgeFolio(words[n - 1]),
                          narrow || tokens[n - 1].rect.minX - tokens[n - 2].rect.maxX > 0.8 * h {
                    found = f
                    numberAt = n - 1
                }
            }
            guard let f = found else { continue }
            folio = folio ?? f
            excluded.formUnion(band)
            if top, words.count > 1 {
                var rest = words
                if let i = numberAt { rest.remove(at: i) }
                let t = rest.joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
                if !t.isEmpty { header = t }
            }
        }
        return (folio, excluded, header)
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
                         region: CGRect, folio: Folio?, headings: Set<Int> = [],
                         runningHeader: String? = nil, notesFrom: Int? = nil) -> LogicalPage {
        var tokens: [LayoutToken] = []
        var lines: [LayoutLine] = []
        var ranges: [NSRange] = []
        var headingRanges: [NSRange] = []
        var notesStart: Int?
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
                // The footnotes start a new paragraph, and so does each numbered note.
                if let notesFrom, ri >= notesFrom,
                   ri == notesFrom || Self.startsWithNoteMarker(row.tokens.first?.text ?? "") {
                    sep = "\n"
                }
                if joinWithoutSpace && sep != "\n" { sep = "" }
                text.append(sep)
            }
            joinWithoutSpace = false
            if let notesFrom, ri == notesFrom { notesStart = text.length }
            let isNote = notesFrom.map { ri >= $0 } ?? false

            let lineStart = tokens.count
            let rowStart = text.length
            let rowMedianH = row.tokens.map(\.rect.height).sorted()[row.tokens.count / 2]
            var needsSpace = false
            for (ti, tok) in row.tokens.enumerated() {
                let prevText = ti > 0 ? row.tokens[ti - 1].text
                    : (ri > 0 && !headings.contains(ri - 1) ? rows[ri - 1].tokens.last?.text : nil)
                let nextText = ti + 1 < row.tokens.count ? row.tokens[ti + 1].text
                    : (ri + 1 < rows.count ? rows[ri + 1].tokens.first?.text : nil)
                // A footnote keeps the number in front of it.
                var display = SymbolCheck.clean(isNote && ti == 0 ? tok.text :
                    noteMarkerStripped(tok, prev: prevText, next: nextText, rowMedianHeight: rowMedianH,
                                       rowMidY: row.midY(atX: tok.rect.midX)))
                if needsSpace && !display.isEmpty { text.append(" ") }
                // "contin-" + "uing" → "continuing"
                if ti == row.tokens.count - 1, ri + 1 < rows.count, display.count > 2, !headings.contains(ri),
                   ri + 1 != notesFrom,
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
            lines.append(LayoutLine(rect: row.pageRect, tokens: lineStart..<tokens.count))
            if headings.contains(ri), text.length > rowStart {
                headingRanges.append(NSRange(location: rowStart, length: text.length - rowStart))
            }
        }

        fixMisreadQuestionMarks(text)

        var index: [TokenKey: Int] = [:]
        for (i, t) in tokens.enumerated() { index[t.key] = i }

        return LogicalPage(
            pdfIndex: pdfIndex, half: half, halfCount: halfCount, region: region,
            tokens: tokens, lines: lines, text: text as String, tokenRanges: ranges,
            folio: folio, indexByKey: index, headingRanges: headingRanges, runningHeader: runningHeader,
            footnoteRanges: notesStart.map { [NSRange(location: $0, length: text.length - $0)] } ?? [])
    }

    /// Footnote reference numbers don't belong in the text (or in what's read aloud):
    /// * glued to a word: "war.12" / "war.”12" / "war¹²" → "war." / "war.”" / "war";
    /// * on their own, set small and raised;
    /// * on their own right after the end of a sentence ("…the war. 12 Then…", or at
    ///   the end of the line) — Vision often reads the raised number at full height;
    /// * on their own after a comma / semicolon / colon when a little smaller.
    /// "p. 12", "No. 3" and numbers that start a lowercase phrase ("12 people") stay.
    static func noteMarkerStripped(_ tok: LayoutToken, prev: String?, next: String?, rowMedianHeight: CGFloat,
                                   rowMidY: CGFloat) -> String {
        let t = tok.text
        let superscripts = "⁰¹²³⁴⁵⁶⁷⁸⁹"
        if !t.isEmpty, t.allSatisfy({ superscripts.contains($0) }) { return "" }
        if ["*", "†", "‡", "§"].contains(t), prev != nil { return "" }
        if t.count <= 3, t.allSatisfy(\.isNumber) {
            let smaller = tok.rect.height < rowMedianHeight * 0.75
            if smaller, tok.rect.midY < rowMidY { return "" }
            if let prev, !isNumberingWord(prev) {
                let p = prev.trimmingCharacters(in: CharacterSet(charactersIn: "”’\"')]»"))
                let startsSentence = next.map { n in
                    let first = n.trimmingCharacters(in: CharacterSet(charactersIn: "“‘\"'([«")).first
                    return first?.isUppercase == true || first == nil
                } ?? true
                let beforeMark = p.dropLast().last
                if let last = p.last, ".!?".contains(last),
                   beforeMark.map({ $0.isLetter || $0.isNumber || ")]".contains($0) }) == true, startsSentence {
                    return ""
                }
                if let last = p.last, ",;:".contains(last), tok.rect.height < rowMedianHeight * 0.88 {
                    return ""
                }
            }
        }
        var out = t
        while let last = out.last, superscripts.contains(last), out.count > 1 { out.removeLast() }
        if let r = out.range(of: #"(?<=\p{Ll}{2}[.,;:!?)\]”’"]{0,2})\d{1,3}$"#, options: .regularExpression) {
            return String(out[..<r.lowerBound])
        }
        return out
    }

    /// A full stop followed by a footnote number (or a smudge) is often read as "?".
    /// A sentence of five words or more ending in "?" that isn't worded like a question
    /// ("…Churchill spoke in London?") gets its full stop back. Same length, so word
    /// positions don't move.
    static func fixMisreadQuestionMarks(_ text: NSMutableString) {
        let ns = text as NSString
        var sentenceStart = 0
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x3F { // "?"
                let sentence = ns.substring(with: NSRange(location: sentenceStart, length: i + 1 - sentenceStart))
                if sentence.split(whereSeparator: \.isWhitespace).count >= 5,
                   !QuestionFinder.looksInterrogative(sentence.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    text.replaceCharacters(in: NSRange(location: i, length: 1), with: ".")
                }
            }
            if c == 0x3F || c == 0x2E || c == 0x21 || c == 0x0A { sentenceStart = i + 1 } // ? . ! newline
            i += 1
        }
    }

    /// Page clutter that is never part of the text: DOIs, links, ©, stamps, ISSN / ISBN.
    static let strongExtraneous = try? NSRegularExpression(pattern:
        #"\bdoi\b|doi\.org|\b10\.\d{4,9}/\S+|https?://|www\.|©|\(c\)\s*(19|20)\d\d|\bissn\b|\bisbn\b|all rights reserved|downloaded (from|by)|this content downloaded|creative commons|\bcc by\b|jstor|terms (and conditions|of use)|for personal use only"#,
        options: [.caseInsensitive])
    /// Publisher-ish words that only count on a short / small / separate line at the foot.
    static let weakExtraneous = try? NSRegularExpression(pattern:
        #"copyright|published (by|online)|university press|\bpress\b.*(19|20)\d\d|licen[cs]ed?\b|reprinted|\bvol\.?\s*\d+.*\bno\.?\s*\d+|accepted:|received:|retrieved from|\.(com|org|net|edu|gov)\b"#,
        options: [.caseInsensitive])

    static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// "p." "pp." "No." "vol." "ch." "fig."… — a number after these is a reference, not a
    /// footnote marker.
    private static func isNumberingWord(_ word: String) -> Bool {
        let w = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "(“‘\"'"))
        return ["p.", "pp.", "no.", "nos.", "vol.", "vols.", "ch.", "chap.", "fig.", "figs.", "art.", "sec.",
                "para.", "n.", "nn.", "ed.", "eds.", "cf.", "v.", "c.", "ca.", "ibid.", "id.", "op.", "pt.",
                "bk.", "l.", "ll.", "vs.", "st.", "rev."].contains(w)
    }
}
