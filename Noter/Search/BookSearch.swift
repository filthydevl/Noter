import Foundation

/// One place a search matched, with a bit of text on either side.
struct SearchHit: Identifiable {
    let id: String
    let location: TextLocation
    let before: String
    let match: String
    let after: String
}

/// Finds a word or a sentence anywhere in the recognized book. Not case sensitive, and
/// whole words only ("war" doesn't match "toward"); curly and straight quotes count as
/// the same. Runs in the background and streams results in book order; the book pages
/// it builds are kept for the next search.
@MainActor
final class BookSearch: ObservableObject {
    @Published var query = "" {
        didSet { if oldValue != query { run() } }
    }
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchedPages = 0
    @Published private(set) var limitReached = false

    nonisolated static let limit = 500

    private weak var session: DocumentSession?
    private var task: Task<Void, Never>?
    private var generation = 0
    /// Book pages by PDF page, for searching again without rebuilding them.
    private var pagesCache: [Int: [LogicalPage]] = [:]

    init(session: DocumentSession) {
        self.session = session
    }

    /// A page was (re-)recognized or the page layout changed.
    func invalidate(_ index: Int? = nil) {
        if let index { pagesCache[index] = nil } else { pagesCache.removeAll() }
    }

    func run() {
        generation += 1
        task?.cancel()
        hits = []
        searchedPages = 0
        limitReached = false
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = session, text.count >= 2, let regex = Self.regex(for: text) else {
            isSearching = false
            return
        }
        isSearching = true
        let gen = generation
        let id = s.info.id, mode = s.info.layoutMode
        let indices = s.ocr.meta.keys.sorted()
        let cache = pagesCache
        task = Task.detached(priority: .userInitiated) { [weak self] in
            // Wait for a pause in typing.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            var batch: [SearchHit] = []
            var built: [Int: [LogicalPage]] = [:]
            var total = 0
            for (n, index) in indices.enumerated() {
                guard !Task.isCancelled else { return }
                var pages = cache[index]
                if pages == nil, let page = Storage.load(OCRPage.self, from: Storage.ocrPageURL(id, index)) {
                    let b = PageLayout.build(page, pdfIndex: index, mode: mode)
                    built[index] = b
                    pages = b
                }
                for lp in pages ?? [] {
                    let found = Self.matches(regex, in: lp, limit: Self.limit - total)
                    total += found.count
                    batch += found
                }
                let last = n == indices.count - 1 || total >= Self.limit
                if batch.count >= 25 || last || n % 20 == 19 {
                    let out = batch, more = built
                    batch = []
                    built = [:]
                    await self?.deliver(out, built: more, searched: n + 1, gen: gen)
                }
                if total >= Self.limit {
                    await self?.finish(gen, limitReached: true)
                    return
                }
            }
            await self?.finish(gen, limitReached: false)
        }
    }

    private func deliver(_ found: [SearchHit], built: [Int: [LogicalPage]], searched: Int, gen: Int) {
        for (k, v) in built { pagesCache[k] = v }
        guard gen == generation else { return }
        hits += found
        searchedPages = searched
    }

    private func finish(_ gen: Int, limitReached: Bool) {
        guard gen == generation else { return }
        isSearching = false
        self.limitReached = limitReached
    }

    // MARK: Matching

    /// Whole words, any case, any run of spaces / line breaks between the words.
    nonisolated static func regex(for query: String) -> NSRegularExpression? {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map {
            NSRegularExpression.escapedPattern(for: String($0))
        }
        guard !words.isEmpty else { return nil }
        let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Curly quotes → straight (one UTF-16 unit each, so offsets don't move).
    nonisolated static func fold(_ s: String) -> String {
        var out = s
        for (a, b) in [("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\"")] {
            out = out.replacingOccurrences(of: a, with: b)
        }
        return out
    }

    nonisolated static func matches(_ regex: NSRegularExpression, in lp: LogicalPage, limit: Int) -> [SearchHit] {
        guard limit > 0, !lp.tokenRanges.isEmpty else { return [] }
        let text = fold(lp.text) as NSString
        var out: [SearchHit] = []
        for m in regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            guard out.count < limit, m.range.length > 0,
                  let lo = lp.tokenIndex(atUTF16: m.range.location),
                  let hi = lp.tokenIndex(atUTF16: NSMaxRange(m.range) - 1) else { continue }
            let original = lp.text as NSString
            let start = max(0, m.range.location - 60)
            let end = min(original.length, NSMaxRange(m.range) + 80)
            func clean(_ s: String) -> String {
                s.replacingOccurrences(of: "\n", with: " ")
            }
            var before = clean(original.substring(with: NSRange(location: start, length: m.range.location - start)))
            var after = clean(original.substring(with: NSRange(location: NSMaxRange(m.range),
                                                                length: end - NSMaxRange(m.range))))
            // Cut at word boundaries.
            if start > 0, let space = before.firstIndex(of: " ") {
                before = "…" + String(before[before.index(after: space)...])
            }
            if end < original.length, let space = after.lastIndex(of: " ") {
                after = String(after[..<space]) + "…"
            }
            out.append(SearchHit(
                id: "\(lp.pdfIndex)-\(lp.half)-\(m.range.location)",
                location: TextLocation(slot: lp.slot, tokens: lo...max(lo, hi)),
                before: before, match: clean(original.substring(with: m.range)), after: after))
        }
        return out
    }
}
