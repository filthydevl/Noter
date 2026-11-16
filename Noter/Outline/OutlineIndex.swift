import Foundation

/// The book's parts — its headings and subheadings, as recognized on the pages — found
/// in the background and kept up to date as pages are recognized. Marked on the page
/// slider while you drag it.
@MainActor
final class OutlineIndex: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: String
        let pdfIndex: Int
        let title: String
        /// The page plus how far down it the heading is (0..<1), for the slider.
        let position: Double
    }

    /// In book order: every heading (a chapter, a section, each source in a collection),
    /// whole even when it wraps onto more lines.
    @Published private(set) var entries: [Entry] = []

    private let docID: UUID
    private let ocr: OCRStore
    private var mode: LayoutMode
    private var generation = 0
    private var pending = Set<Int>()
    private var results: [Int: [(String, Double)]] = [:]
    private var worker: Task<Void, Never>?
    private var sincePublish = 0

    init(docID: UUID, ocr: OCRStore, mode: LayoutMode) {
        self.docID = docID
        self.ocr = ocr
        self.mode = mode
    }

    func start() {
        enqueue(Array(ocr.meta.keys))
    }

    func pageReady(_ index: Int) {
        enqueue([index])
    }

    func reset(mode: LayoutMode) {
        self.mode = mode
        generation += 1
        worker?.cancel()
        worker = nil
        pending.removeAll()
        results.removeAll()
        entries = []
        start()
    }

    func stop() {
        generation += 1
        worker?.cancel()
        worker = nil
        pending.removeAll()
    }

    /// The part a PDF page belongs to: the last heading before it, or its first heading
    /// if that's near the top of the page.
    func part(at pdfIndex: Int) -> Entry? {
        entries.last { $0.pdfIndex < pdfIndex || ($0.pdfIndex == pdfIndex && $0.position - Double(pdfIndex) < 0.35) }
            ?? entries.last { $0.pdfIndex <= pdfIndex }
    }

    private func enqueue(_ pages: [Int]) {
        pending.formUnion(pages)
        guard worker == nil, !pending.isEmpty else { return }
        let id = docID, mode = self.mode, gen = generation
        worker = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled, let index = await self?.takeNext(gen) {
                var found: [(String, Double)] = []
                if let page = Storage.load(OCRPage.self, from: Storage.ocrPageURL(id, index)) {
                    let halves = PageLayout.build(page, pdfIndex: index, mode: mode)
                    for (h, lp) in halves.enumerated() {
                        found += Self.headings(in: lp, half: h, of: halves.count)
                    }
                }
                await self?.finish(index, found, gen)
            }
            await self?.workerEnded(gen)
        }
    }

    /// A page's headings with how far down the page each is. Lines of one heading
    /// (it wrapped) are joined.
    nonisolated private static func headings(in lp: LogicalPage, half: Int, of halves: Int) -> [(String, Double)] {
        let text = lp.text as NSString
        guard text.length > 0 else { return [] }
        var merged: [NSRange] = []
        for r in lp.headingRanges.sorted(by: { $0.location < $1.location }) where NSMaxRange(r) <= text.length {
            if let last = merged.last {
                let between = NSRange(location: NSMaxRange(last), length: max(r.location - NSMaxRange(last), 0))
                if text.substring(with: between).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    merged[merged.count - 1] = NSUnionRange(last, r)
                    continue
                }
            }
            merged.append(r)
        }
        return merged.compactMap { r in
            let t = text.substring(with: r).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard t.count >= 2, t.count <= 240, t.contains(where: \.isLetter) else { return nil }
            // How far through the page's text: close enough to how far down it is.
            let within = Double(r.location) / Double(text.length)
            return (t, min((Double(half) + within) / Double(max(halves, 1)), 0.99))
        }
    }

    private func takeNext(_ gen: Int) -> Int? {
        guard gen == generation, let next = pending.min() else { return nil }
        pending.remove(next)
        return next
    }

    private func finish(_ index: Int, _ found: [(String, Double)], _ gen: Int) {
        guard gen == generation else { return }
        results[index] = found.isEmpty ? nil : found
        sincePublish += 1
        if sincePublish >= 20 || pending.isEmpty { publish() }
    }

    private func workerEnded(_ gen: Int) {
        guard gen == generation else { return }
        worker = nil
        publish()
        if !pending.isEmpty { enqueue([]) }
    }

    private func publish() {
        sincePublish = 0
        let list = results.keys.sorted().flatMap { i in
            (results[i] ?? []).enumerated().map { k, item in
                Entry(id: "\(i)-\(k)", pdfIndex: i, title: item.0, position: Double(i) + item.1)
            }
        }
        if list != entries { entries = list }
    }
}
