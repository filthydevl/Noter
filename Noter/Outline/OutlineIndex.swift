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
    }

    /// In book order, at most one per PDF page (its first heading).
    @Published private(set) var entries: [Entry] = []

    private let docID: UUID
    private let ocr: OCRStore
    private var mode: LayoutMode
    private var generation = 0
    private var pending = Set<Int>()
    private var results: [Int: String] = [:]
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

    /// The part a PDF page belongs to: the last heading at or before it.
    func part(at pdfIndex: Int) -> Entry? {
        entries.last { $0.pdfIndex <= pdfIndex }
    }

    private func enqueue(_ pages: [Int]) {
        pending.formUnion(pages)
        guard worker == nil, !pending.isEmpty else { return }
        let id = docID, mode = self.mode, gen = generation
        worker = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled, let index = await self?.takeNext(gen) {
                var title: String?
                if let page = Storage.load(OCRPage.self, from: Storage.ocrPageURL(id, index)) {
                    for lp in PageLayout.build(page, pdfIndex: index, mode: mode) {
                        let text = lp.text as NSString
                        for r in lp.headingRanges where NSMaxRange(r) <= text.length {
                            let t = text.substring(with: r)
                                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                            if t.count >= 2, t.count <= 90, t.contains(where: \.isLetter) {
                                title = t
                                break
                            }
                        }
                        if title != nil { break }
                    }
                }
                await self?.finish(index, title, gen)
            }
            await self?.workerEnded(gen)
        }
    }

    private func takeNext(_ gen: Int) -> Int? {
        guard gen == generation, let next = pending.min() else { return nil }
        pending.remove(next)
        return next
    }

    private func finish(_ index: Int, _ title: String?, _ gen: Int) {
        guard gen == generation else { return }
        results[index] = title
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
        let list = results.keys.sorted().compactMap { i in
            results[i].map { Entry(id: "\(i)", pdfIndex: i, title: $0) }
        }
        if list != entries { entries = list }
    }
}
