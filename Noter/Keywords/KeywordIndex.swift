import Foundation

/// One place a key word appears.
struct KeywordOccurrence: Hashable {
    let slot: SlotKey
    let tokens: ClosedRange<Int>
}

struct Keyword: Identifiable {
    let id: String
    let text: String
    let kind: KeywordKind
    /// In book order.
    let occurrences: [KeywordOccurrence]
    let pageCount: Int

    var count: Int { occurrences.count }

    /// The first mention on each book page, for the page-number pills.
    var firstPerPage: [KeywordOccurrence] {
        var seen = Set<SlotKey>()
        return occurrences.filter { seen.insert($0.slot).inserted }
    }
}

/// Book-wide key words, built in the background from the OCR'd pages and kept up to
/// date as more pages are recognized.
@MainActor
final class KeywordIndex: ObservableObject {
    @Published private(set) var keywords: [Keyword] = []
    @Published private(set) var scannedPages = 0
    @Published private(set) var isScanning = false
    /// Show key words on the pages (PDF and text views).
    @Published var markOnPages: Bool {
        didSet {
            guard oldValue != markOnPages else { return }
            UserDefaults.standard.set(markOnPages, forKey: Self.markKey)
            if markOnPages { start() }
            onChange?()
        }
    }

    /// Called whenever the key words or their visibility change.
    var onChange: (() -> Void)?

    private static let markKey = "noter.markKeywords"
    private let docID: UUID
    private let ocr: OCRStore
    private var mode: LayoutMode
    private var started = false
    private var generation = 0
    private var pending = Set<Int>()
    private var results: [Int: [PageKeywords]] = [:]
    private var sinceAggregate = 0
    private var worker: Task<Void, Never>?
    private var bySlot: [SlotKey: [ClosedRange<Int>]] = [:]

    init(docID: UUID, ocr: OCRStore, mode: LayoutMode) {
        self.docID = docID
        self.ocr = ocr
        self.mode = mode
        self.markOnPages = UserDefaults.standard.bool(forKey: Self.markKey)
    }

    /// Key word token ranges on a book page.
    func ranges(on slot: SlotKey) -> [ClosedRange<Int>] {
        bySlot[slot] ?? []
    }

    // MARK: Building

    /// Starts scanning every page that has been recognized so far (once).
    func start() {
        guard !started else { return }
        started = true
        enqueue(Array(ocr.meta.keys))
    }

    func pageReady(_ index: Int) {
        guard started else { return }
        enqueue([index])
    }

    /// Page layout changed: book pages (and so key word positions) are different.
    func reset(mode: LayoutMode) {
        self.mode = mode
        generation += 1
        worker?.cancel()
        worker = nil
        pending.removeAll()
        results.removeAll()
        bySlot.removeAll()
        keywords = []
        scannedPages = 0
        isScanning = false
        onChange?()
        if started { enqueue(Array(ocr.meta.keys)) }
    }

    func stop() {
        generation += 1
        worker?.cancel()
        worker = nil
        pending.removeAll()
        isScanning = false
    }

    private func enqueue(_ pages: [Int]) {
        pending.formUnion(pages.filter { results[$0] == nil })
        guard worker == nil, !pending.isEmpty else { return }
        isScanning = true
        let id = docID, mode = self.mode, gen = generation
        worker = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled, let index = await self?.takeNext(gen) {
                var found: [PageKeywords] = []
                if let page = Storage.load(OCRPage.self, from: Storage.ocrPageURL(id, index)) {
                    found = PageLayout.build(page, pdfIndex: index, mode: mode).map {
                        PageKeywords(slot: $0.slot, items: KeywordExtractor.candidates(in: $0))
                    }
                }
                await self?.finish(index, found, gen)
            }
            await self?.workerEnded(gen)
        }
    }

    private func takeNext(_ gen: Int) -> Int? {
        guard gen == generation, let next = pending.min() else { return nil }
        pending.remove(next)
        return next
    }

    private func finish(_ index: Int, _ found: [PageKeywords], _ gen: Int) {
        guard gen == generation else { return }
        results[index] = found
        scannedPages = results.count
        sinceAggregate += 1
        // Publish in batches so a big book doesn't re-sort the list on every page.
        if sinceAggregate >= 12 || pending.isEmpty { aggregate() }
    }

    private func workerEnded(_ gen: Int) {
        guard gen == generation else { return }
        worker = nil
        if pending.isEmpty {
            isScanning = false
            aggregate()
        } else {
            enqueue([])
        }
    }

    // MARK: Ranking

    private func aggregate() {
        sinceAggregate = 0
        struct Acc {
            var kind: KeywordKind
            var displays: [String: Int] = [:]
            var occurrences: [KeywordOccurrence] = []
            var slots = Set<SlotKey>()
        }
        var accs: [String: Acc] = [:]
        for index in results.keys.sorted() {
            for page in results[index] ?? [] {
                for c in page.items {
                    let id = c.kind.rawValue + "|" + c.key
                    var a = accs[id] ?? Acc(kind: c.kind)
                    a.displays[c.display, default: 0] += 1
                    a.occurrences.append(KeywordOccurrence(slot: page.slot, tokens: c.tokens))
                    a.slots.insert(page.slot)
                    accs[id] = a
                }
            }
        }

        var all: [Keyword] = []
        for (id, a) in accs {
            // Most common spelling wins ("Churchill" over "CHURCHILL").
            guard let display = a.displays.max(by: { x, y in
                x.value != y.value ? x.value < y.value : x.key > y.key
            })?.key else { continue }
            all.append(Keyword(id: id, text: display, kind: a.kind, occurrences: a.occurrences,
                               pageCount: a.slots.count))
        }

        // Key terms must recur across pages; a single word that mostly appears inside
        // a kept two-word term ("effort" in "war effort") is dropped.
        let phrases = all.filter { $0.kind == .term && $0.text.contains(" ") && $0.count >= 2 && $0.pageCount >= 2 }
        all = all.filter { k in
            guard k.kind == .term else { return true }
            if k.text.contains(" ") { return k.count >= 2 && k.pageCount >= 2 }
            guard k.count >= 3, k.pageCount >= 2 else { return false }
            let covered = phrases
                .filter { $0.text.split(separator: " ").contains(Substring(k.text)) }
                .reduce(0) { $0 + $1.count }
            return Double(covered) < Double(k.count) * 0.7
        }

        var kept: [Keyword] = []
        for kind in KeywordKind.allCases {
            let ranked = all.filter { $0.kind == kind }.sorted {
                $0.count != $1.count ? $0.count > $1.count
                    : $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending
            }
            kept += ranked.prefix(kind.limit)
        }
        keywords = kept

        var map: [SlotKey: [ClosedRange<Int>]] = [:]
        for k in kept {
            for o in k.occurrences { map[o.slot, default: []].append(o.tokens) }
        }
        bySlot = map
        onChange?()
    }
}
