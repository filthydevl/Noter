import Foundation
import CoreGraphics

/// Kinds of text the reader can skip while reading aloud (like Speechify's "Skip content").
struct SkipOptions: OptionSet, Hashable {
    let rawValue: Int

    static let headersFooters = SkipOptions(rawValue: 1 << 0)
    static let footnotes = SkipOptions(rawValue: 1 << 1)
    static let citations = SkipOptions(rawValue: 1 << 2)
    static let parentheses = SkipOptions(rawValue: 1 << 3)
    static let brackets = SkipOptions(rawValue: 1 << 4)
    static let links = SkipOptions(rawValue: 1 << 5)

    static let defaults: SkipOptions = [.headersFooters, .citations, .links]

    struct Item: Identifiable {
        let option: SkipOptions
        let title: String
        var id: Int { option.rawValue }
    }

    static let items: [Item] = [
        Item(option: .headersFooters, title: "Headers & footers"),
        Item(option: .footnotes, title: "Footnotes"),
        Item(option: .citations, title: "Citations"),
        Item(option: .parentheses, title: "Parentheses ( )"),
        Item(option: .brackets, title: "Brackets [ ]"),
        Item(option: .links, title: "Links & emails"),
    ]
}

/// Finds the parts of a book page that should not be read aloud.
enum SkipFilter {
    /// Sorted, non-overlapping UTF-16 ranges of `page.text` to skip.
    static func excludedRanges(in page: LogicalPage, options: SkipOptions) -> [NSRange] {
        guard !options.isEmpty, !page.tokens.isEmpty else { return [] }
        var ranges: [NSRange] = []

        for li in skippedLines(page, options: options).sorted() {
            let t = page.lines[li].tokens
            guard !t.isEmpty else { continue }
            ranges.append(page.textRange(for: t.lowerBound...(t.upperBound - 1)))
        }

        var patterns: [NSRegularExpression] = []
        if options.contains(.parentheses), let parentheses { patterns.append(parentheses) }
        if options.contains(.brackets), let brackets { patterns.append(brackets) }
        if options.contains(.citations) { patterns += citations }
        if options.contains(.links) { patterns += links }
        let whole = NSRange(location: 0, length: (page.text as NSString).length)
        for regex in patterns {
            for m in regex.matches(in: page.text, range: whole) where m.range.length > 0 {
                ranges.append(m.range)
            }
        }
        return merged(ranges)
    }

    // MARK: Whole lines: running headers, footers, footnotes

    static func skippedLines(_ page: LogicalPage, options: SkipOptions) -> Set<Int> {
        var out = Set<Int>()
        let lines = page.lines
        guard lines.count >= 2 else { return out }
        let heights = lines.map(\.rect.height).sorted()
        let medianH = max(heights[heights.count / 2], 0.002)

        if options.contains(.headersFooters) {
            // A short line alone in the top / bottom margin, set apart from the body.
            let first = lines[0]
            if first.rect.midY < 0.10, first.tokens.count <= 12,
               lines[1].rect.minY - first.rect.maxY > medianH * 0.9 {
                out.insert(0)
            }
            let li = lines.count - 1
            let last = lines[li]
            if last.rect.midY > 0.90, last.tokens.count <= 12,
               last.rect.minY - lines[li - 1].rect.maxY > medianH * 0.9 {
                out.insert(li)
            }
        }

        if options.contains(.footnotes) {
            // A block of smaller lines at the bottom of the page, set apart from the
            // body by a gap or starting with a note marker (1, *, †…).
            var i = lines.count - 1
            if out.contains(i) { i -= 1 }
            var block: [Int] = []
            while i > 0, lines[i].rect.midY > 0.5, lines[i].rect.height < medianH * 0.86 {
                block.append(i)
                i -= 1
            }
            if let top = block.last, i >= 0, block.count < lines.count / 2 + 1 {
                let gap = lines[top].rect.minY - lines[i].rect.maxY
                let firstWord = page.tokens[lines[top].tokens.lowerBound].text
                let marker = firstWord.first.map { $0.isNumber || "*†‡§".contains($0) } ?? false
                if gap > medianH * 0.8 || marker { out.formUnion(block) }
            }
        }
        return out
    }

    // MARK: Patterns

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            assertionFailure("Noter: bad skip pattern \(pattern): \(error)")
            return nil
        }
    }

    private static let parentheses = regex(#"\([^()]{0,400}\)"#)
    private static let brackets = regex(#"\[[^\[\]]{0,400}\]"#)

    private static let citations: [NSRegularExpression] = [
        // [12]  [3, 4]  [12–14]
        regex(#"\[\s*\d{1,4}(?:\s*[-–,;]\s*\d{1,4})*\s*\]"#),
        // (Smith 2004)  (see Smith and Jones, 2004: 12)  (Smith et al. 1999, p. 4)
        regex(#"\((?:see\s+|cf\.\s+)?[^()]{0,80}?\p{Lu}[\p{L}'’\-]+(?:\s+(?:and|&|et al\.?)\s+\p{Lu}?[\p{L}'’\-]*)?,?\s+(?:1[5-9]|20)\d{2}[a-z]?(?:[,:]\s*(?:pp?\.\s*)?\d[\d–\-]*)?\s*\)"#),
        // (ibid.)  (op. cit., 23)
        regex(#"\((?:ibid|ibidem|op\.\s*cit)\.?[^()]{0,40}\)"#, [.caseInsensitive]),
        // Note numbers stuck to a word: "war.12", "women3,"
        regex(#"(?<=\p{Ll}{2}[.,;:)\]”’"]?)\d{1,3}(?=[\s.,;:]|$)"#),
    ].compactMap { $0 }

    private static let links: [NSRegularExpression] = [
        regex(#"(?:https?://|www\.)\S+"#, [.caseInsensitive]),
        regex(#"[\w.+\-]+@[\w\-]+(?:\.[\w\-]+)+"#),
        regex(#"\b[\w\-]+(?:\.[\w\-]+)*\.(?:com|org|net|edu|gov|io|co|uk)(?:/\S*)?"#),
    ].compactMap { $0 }

    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var out: [NSRange] = []
        for r in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = out.last, r.location <= NSMaxRange(last) {
                out[out.count - 1] = NSRange(location: last.location,
                                            length: max(NSMaxRange(last), NSMaxRange(r)) - last.location)
            } else {
                out.append(r)
            }
        }
        return out
    }
}
