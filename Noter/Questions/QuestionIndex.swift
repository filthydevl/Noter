import Foundation

/// Where something is on a book page: used to jump there and blink it.
struct TextLocation: Hashable {
    let slot: SlotKey
    let tokens: ClosedRange<Int>
}

struct Question: Identifiable {
    let id: String
    let text: String
    let kind: QuestionKind
    let location: TextLocation
}

/// Every question in the book, found in the background from the OCR'd pages and kept
/// up to date as more pages are recognized.
@MainActor
final class QuestionIndex: ObservableObject {
    @Published private(set) var questions: [Question] = []
    @Published private(set) var scannedPages = 0
    @Published private(set) var isScanning = false
    /// Highlight the questions on the pages (PDF and text views).
    @Published var markOnPages: Bool {
        didSet {
            guard oldValue != markOnPages else { return }
            UserDefaults.standard.set(markOnPages, forKey: Self.markKey)
            if markOnPages { start() }
            onChange?()
        }
    }

    /// Called whenever the questions or their visibility change.
    var onChange: (() -> Void)?

    private static let markKey = "noter.markQuestions"
    private let docID: UUID
    private let ocr: OCRStore
    private var mode: LayoutMode
    private var started = false
    private var generation = 0
    private var pending = Set<Int>()
    private var results: [Int: [(slot: SlotKey, items: [QuestionCandidate])]] = [:]
    private var sincePublish = 0
    private var worker: Task<Void, Never>?
    private var bySlot: [SlotKey: [ClosedRange<Int>]] = [:]

    init(docID: UUID, ocr: OCRStore, mode: LayoutMode) {
        self.docID = docID
        self.ocr = ocr
        self.mode = mode
        self.markOnPages = UserDefaults.standard.bool(forKey: Self.markKey)
    }

    /// Question token ranges on a book page.
    func ranges(on slot: SlotKey) -> [ClosedRange<Int>] {
        bySlot[slot] ?? []
    }

    // MARK: Scanning

    /// Starts scanning every page that has been recognized so far (once).
    func start() {
        guard !started else { return }
        started = true
        enqueue(Array(ocr.meta.keys))
    }

    /// A page was (re-)recognized: scan it (again).
    func pageReady(_ index: Int) {
        guard started else { return }
        results[index] = nil
        enqueue([index])
    }

    /// Page layout changed: book pages (and so question positions) are different.
    func reset(mode: LayoutMode) {
        self.mode = mode
        generation += 1
        worker?.cancel()
        worker = nil
        pending.removeAll()
        results.removeAll()
        bySlot.removeAll()
        questions = []
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
                var found: [(slot: SlotKey, items: [QuestionCandidate])] = []
                if let page = Storage.load(OCRPage.self, from: Storage.ocrPageURL(id, index)) {
                    found = PageLayout.build(page, pdfIndex: index, mode: mode).map {
                        (slot: $0.slot, items: QuestionFinder.questions(in: $0))
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

    private func finish(_ index: Int, _ found: [(slot: SlotKey, items: [QuestionCandidate])], _ gen: Int) {
        guard gen == generation else { return }
        results[index] = found
        scannedPages = results.count
        sincePublish += 1
        // Publish in batches so a big book doesn't rebuild the list on every page.
        if sincePublish >= 12 || pending.isEmpty { publish() }
    }

    private func workerEnded(_ gen: Int) {
        guard gen == generation else { return }
        worker = nil
        if pending.isEmpty {
            isScanning = false
            publish()
        } else {
            enqueue([])
        }
    }

    private func publish() {
        sincePublish = 0
        var list: [Question] = []
        var map: [SlotKey: [ClosedRange<Int>]] = [:]
        for index in results.keys.sorted() {
            for page in results[index] ?? [] {
                for q in page.items {
                    let location = TextLocation(slot: page.slot, tokens: q.tokens)
                    list.append(Question(
                        id: "\(page.slot.pdfIndex)-\(page.slot.half)-\(q.tokens.lowerBound)",
                        text: q.text, kind: q.kind, location: location))
                    map[page.slot, default: []].append(q.tokens)
                }
            }
        }
        questions = list
        bySlot = map
        onChange?()
    }
}
