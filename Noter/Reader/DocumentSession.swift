import SwiftUI
import UIKit
import PDFKit

/// Everything about one open document: the PDF, OCR, highlights, page numbers,
/// reading position and text-to-speech. The PDF and transcript views are thin UIKit
/// layers that talk to this object.
@MainActor
final class DocumentSession: ObservableObject {
    @Published var info: DocumentInfo
    @Published private(set) var highlights: [Highlight] = []
    @Published var viewMode: ViewMode {
        didSet {
            guard oldValue != viewMode else { return }
            if viewMode != .highlights {
                lastReadingMode = viewMode
                info.viewMode = viewMode
                saveInfo()
            }
            syncPositionForCurrentMode()
        }
    }
    @Published var tool: PencilTool = .highlight
    @Published var color: HighlightColor {
        didSet { UserDefaults.standard.set(color.rawValue, forKey: "noter.highlightColor") }
    }
    @Published var transcriptFontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(transcriptFontSize), forKey: "noter.fontSize")
            transcriptController?.reloadAll()
        }
    }
    @Published private(set) var ocrDone = 0
    @Published private(set) var currentPage = 0
    @Published private(set) var canUndo = false
    @Published private(set) var toast: String?
    @Published private(set) var speechPosition: SpeechPosition?
    @Published private(set) var labelsVersion = 0

    let pdf: PDFDocument
    let ocr: OCRStore
    let speech: SpeechController
    let keywords: KeywordIndex
    weak var pdfController: PDFReaderController?
    weak var transcriptController: TranscriptController?

    private(set) var lastReadingMode: ViewMode = .pdf
    private var byPage: [Int: [Highlight]] = [:]
    private var layoutCache: [Int: [LogicalPage]] = [:]
    private var labels: [SlotKey: String] = [:]
    private var undoStack: [[Highlight]] = []
    private var lastUserActivity = Date.distantPast
    private var toastTask: Task<Void, Never>?

    var pageCount: Int { pdf.pageCount }
    var secondsSinceUserActivity: TimeInterval { Date().timeIntervalSince(lastUserActivity) }

    init?(info: DocumentInfo) {
        guard let pdf = PDFDocument(url: Storage.pdfURL(info.id)), pdf.pageCount > 0 else { return nil }
        self.pdf = pdf
        var info = info
        info.lastOpened = Date()
        self.info = info
        let ocr = OCRStore(docID: info.id, pageCount: pdf.pageCount)
        self.ocr = ocr
        self.speech = SpeechController()
        self.keywords = KeywordIndex(docID: info.id, ocr: ocr, mode: info.layoutMode)
        let defaults = UserDefaults.standard
        self.color = HighlightColor(rawValue: defaults.string(forKey: "noter.highlightColor") ?? "") ?? .yellow
        let fontSize = defaults.double(forKey: "noter.fontSize")
        self.transcriptFontSize = fontSize > 0 ? CGFloat(fontSize) : 21
        let startMode: ViewMode = info.viewMode == .highlights ? .pdf : info.viewMode
        self.viewMode = startMode
        self.lastReadingMode = startMode
        self.currentPage = max(0, min(info.lastPage, pdf.pageCount - 1))
        self.highlights = Storage.load([Highlight].self, from: Storage.highlightsURL(info.id)) ?? []

        rebuildIndex()
        speech.session = self
        ocr.onPageReady = { [weak self] index in self?.pageReady(index) }
        keywords.onChange = { [weak self] in self?.keywordsChanged() }
        if keywords.markOnPages { keywords.start() }
        ocr.setFocus(currentPage)
        ocrDone = ocr.doneCount
        recomputeLabels()
        saveInfo()
        ocr.start()
    }

    func close() {
        speech.stop()
        keywords.stop()
        ocr.stop()
        saveAll()
    }

    func saveAll() {
        saveInfo()
        Storage.save(highlights, to: Storage.highlightsURL(info.id))
        HighlightExporter.export(self)
    }

    func saveInfo() {
        Storage.save(info, to: Storage.infoURL(info.id))
    }

    // MARK: - Pages

    func logicalPages(_ pdfIndex: Int) -> [LogicalPage]? {
        if let cached = layoutCache[pdfIndex] { return cached }
        guard let page = ocr.page(pdfIndex) else { return nil }
        let built = PageLayout.build(page, pdfIndex: pdfIndex, mode: info.layoutMode)
        if layoutCache.count > 60 { layoutCache.removeAll() }
        layoutCache[pdfIndex] = built
        return built
    }

    func logicalPage(_ slot: SlotKey) -> LogicalPage? {
        guard let pages = logicalPages(slot.pdfIndex), slot.half >= 0, slot.half < pages.count else { return nil }
        return pages[slot.half]
    }

    /// Number of book pages on a PDF page (1 until it has been OCR'd).
    func halfCount(_ pdfIndex: Int) -> Int {
        ocr.meta[pdfIndex]?.split(info.layoutMode).folios.count ?? 1
    }

    func setCurrentPage(_ index: Int) {
        guard index != currentPage, index >= 0, index < pageCount else { return }
        currentPage = index
        ocr.setFocus(index)
        info.lastPage = index
        saveInfo()
    }

    func setLayoutMode(_ mode: LayoutMode) {
        guard mode != info.layoutMode else { return }
        speech.stop()
        info.layoutMode = mode
        saveInfo()
        layoutCache.removeAll()
        keywords.reset(mode: mode)
        recomputeLabels()
        transcriptController?.reloadAll()
        HighlightExporter.export(self)
    }

    private func pageReady(_ index: Int) {
        layoutCache[index] = nil
        ocrDone = ocr.doneCount
        info.ocrPagesDone = ocrDone
        saveInfo()
        recomputeLabels()
        transcriptController?.pageBecameReady(index)
        keywords.pageReady(index)
        if ocr.isComplete { HighlightExporter.export(self) }
    }

    func readingStartSlot() -> SlotKey {
        if viewMode == .transcript, let slot = transcriptController?.topVisibleSlot() { return slot }
        return SlotKey(pdfIndex: currentPage, half: 0)
    }

    private func syncPositionForCurrentMode() {
        switch viewMode {
        case .pdf: pdfController?.goTo(page: currentPage, rect: nil)
        case .transcript: transcriptController?.scroll(toPage: currentPage)
        case .highlights: break
        }
    }

    // MARK: - Page numbers

    private func recomputeLabels() {
        var slots: [SlotKey] = []
        var folios: [Folio?] = []
        var lastKnownCount = info.layoutMode == .spread ? 2 : 1
        for i in 0..<pageCount {
            if let split = ocr.meta[i]?.split(info.layoutMode) {
                lastKnownCount = split.folios.count
                for (h, f) in split.folios.enumerated() {
                    slots.append(SlotKey(pdfIndex: i, half: h))
                    folios.append(f)
                }
            } else {
                for h in 0..<lastKnownCount {
                    slots.append(SlotKey(pdfIndex: i, half: h))
                    folios.append(nil)
                }
            }
        }
        let result = PageLabeler.labels(for: folios)
        var map: [SlotKey: String] = [:]
        for (slot, label) in zip(slots, result) {
            if let label { map[slot] = label }
        }
        labels = map
        labelsVersion += 1
        transcriptController?.refreshHeaders()
    }

    /// "p. 24" — the page number printed in the book. Falls back to the PDF page.
    func label(for slot: SlotKey) -> String {
        if let l = labels[slot] { return "p. \(l)" }
        if halfCount(slot.pdfIndex) > 1 {
            return "PDF page \(slot.pdfIndex + 1) (\(slot.half == 0 ? "left" : "right"))"
        }
        return "PDF page \(slot.pdfIndex + 1)"
    }

    func headerLabel(for slot: SlotKey) -> String {
        if let l = labels[slot] {
            let side = halfCount(slot.pdfIndex) > 1 ? (slot.half == 0 ? " left" : " right") : ""
            return "Page \(l)   ·   PDF \(slot.pdfIndex + 1)\(side)"
        }
        return label(for: slot)
    }

    func half(of h: Highlight) -> Int {
        guard let g = ocr.meta[h.page]?.split(info.layoutMode).gutter, let r = h.rects.first else { return 0 }
        return r.midX >= g ? 1 : 0
    }

    func pageLabel(for h: Highlight) -> String {
        label(for: SlotKey(pdfIndex: h.page, half: half(of: h)))
    }

    // MARK: - Highlights

    func highlights(onPage page: Int) -> [Highlight] {
        byPage[page] ?? []
    }

    func sortedHighlights() -> [Highlight] {
        highlights.sorted { a, b in
            let ka = (a.page, half(of: a), a.rects.first?.minY ?? 0, a.rects.first?.minX ?? 0)
            let kb = (b.page, half(of: b), b.rects.first?.minY ?? 0, b.rects.first?.minX ?? 0)
            return ka < kb
        }
    }

    /// Adds a highlight for a word range, merging with any highlight it overlaps
    /// (or touches, if the colors match) so repeated strokes never stack up.
    func addHighlight(on lp: LogicalPage, range: ClosedRange<Int>) {
        guard !lp.tokens.isEmpty, range.upperBound < lp.tokens.count, range.lowerBound >= 0 else { return }
        var lo = range.lowerBound, hi = range.upperBound
        var absorbed = Set<UUID>()
        var changed = true
        while changed {
            changed = false
            for h in highlights(onPage: lp.pdfIndex) where !absorbed.contains(h.id) {
                guard let r = lp.range(of: h) else { continue }
                let overlaps = r.lowerBound <= hi && r.upperBound >= lo
                let touches = h.color == color && r.lowerBound <= hi + 1 && r.upperBound >= lo - 1
                if overlaps || touches {
                    lo = min(lo, r.lowerBound)
                    hi = max(hi, r.upperBound)
                    absorbed.insert(h.id)
                    changed = true
                }
            }
        }
        let merged = lo...hi
        let h = Highlight(
            id: UUID(), page: lp.pdfIndex, spans: lp.spans(for: merged), rects: lp.lineRects(for: merged),
            text: lp.string(for: merged), color: color, created: Date())
        pushUndo()
        highlights.removeAll { absorbed.contains($0.id) }
        highlights.append(h)
        highlightsChanged()
    }

    func removeHighlights(_ ids: Set<UUID>, registerUndo: Bool = true) {
        guard !ids.isEmpty else { return }
        if registerUndo { pushUndo() }
        highlights.removeAll { ids.contains($0.id) }
        highlightsChanged()
    }

    /// Highlights on a PDF page touched by any of the normalized points (eraser).
    func highlightIDs(onPage page: Int, hitBy points: [CGPoint]) -> Set<UUID> {
        var ids = Set<UUID>()
        for h in highlights(onPage: page) {
            let hit = h.rects.contains { r in
                let grown = r.insetBy(dx: -0.004, dy: -0.004)
                return points.contains { grown.contains($0) }
            }
            if hit { ids.insert(h.id) }
        }
        return ids
    }

    func transcriptHighlightRanges(_ lp: LogicalPage) -> [(NSRange, UIColor)] {
        highlights(onPage: lp.pdfIndex).compactMap { h in
            guard let r = lp.range(of: h) else { return nil }
            return (lp.textRange(for: r), h.color.uiColor)
        }
    }

    /// Parts of a book page that read-aloud skips (dimmed in the text view).
    func skippedRanges(_ lp: LogicalPage) -> [NSRange] {
        SkipFilter.excludedRanges(in: lp, options: speech.skip)
    }

    func skipOptionsChanged() {
        transcriptController?.refreshSkipped()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        highlights = previous
        canUndo = !undoStack.isEmpty
        highlightsChanged()
    }

    func toggleTool() {
        tool = tool == .highlight ? .erase : .highlight
        showToast(tool == .highlight ? "Highlighter" : "Eraser")
    }

    /// Jumps to a highlight and blinks a box around it.
    func open(_ h: Highlight) {
        setCurrentPage(h.page)
        let mode = lastReadingMode
        viewMode = mode
        noteUserActivity() // don't let read-along scroll away from it
        if mode == .pdf {
            pdfController?.goTo(page: h.page, rect: h.rects.first)
            pdfController?.flash(pageIndex: h.page, rects: h.rects)
        } else {
            let slot = SlotKey(pdfIndex: h.page, half: half(of: h))
            transcriptController?.scroll(toPage: h.page, half: slot.half)
            if let lp = logicalPage(slot), let r = lp.range(of: h) {
                transcriptController?.flash(slot: slot, range: lp.textRange(for: r))
            }
        }
    }

    /// Jumps to one mention of a key word and blinks a box around it.
    func open(_ occurrence: KeywordOccurrence) {
        let slot = occurrence.slot
        setCurrentPage(slot.pdfIndex)
        let mode = lastReadingMode
        viewMode = mode
        noteUserActivity()
        guard let lp = logicalPage(slot), occurrence.tokens.upperBound < lp.tokens.count else { return }
        if mode == .pdf {
            let rects = lp.lineRects(for: occurrence.tokens)
            pdfController?.goTo(page: slot.pdfIndex, rect: rects.first)
            pdfController?.flash(pageIndex: slot.pdfIndex, rects: rects)
        } else {
            transcriptController?.scroll(toPage: slot.pdfIndex, half: slot.half)
            transcriptController?.flash(slot: slot, range: lp.textRange(for: occurrence.tokens))
        }
    }

    // MARK: - Key words

    /// Key word token ranges to mark on a book page (empty unless "Mark on pages" is on).
    func keywordRanges(_ lp: LogicalPage) -> [ClosedRange<Int>] {
        guard keywords.markOnPages else { return [] }
        return keywords.ranges(on: lp.slot).filter { $0.upperBound < lp.tokens.count }
    }

    func keywordTextRanges(_ lp: LogicalPage) -> [NSRange] {
        keywordRanges(lp).map { lp.textRange(for: $0) }
    }

    private func keywordsChanged() {
        pdfController?.refreshKeywordMarks()
        transcriptController?.refreshKeywordMarks()
    }

    private func pushUndo() {
        undoStack.append(highlights)
        if undoStack.count > 100 { undoStack.removeFirst() }
        canUndo = true
    }

    private func rebuildIndex() {
        byPage = Dictionary(grouping: highlights, by: \.page)
    }

    /// Auto-save: every change is written to disk immediately.
    private func highlightsChanged() {
        rebuildIndex()
        Storage.save(highlights, to: Storage.highlightsURL(info.id))
        info.highlightCount = highlights.count
        saveInfo()
        HighlightExporter.export(self)
        pdfController?.syncHighlights()
        transcriptController?.refreshHighlights()
    }

    // MARK: - Speech / activity

    func speechMoved(_ position: SpeechPosition?) {
        speechPosition = position
        pdfController?.showSpeech(position)
        transcriptController?.showSpeech(position)
    }

    func noteUserActivity() {
        lastUserActivity = Date()
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

extension HighlightColor {
    var uiColor: UIColor {
        switch self {
        case .yellow: UIColor(red: 1.00, green: 0.84, blue: 0.10, alpha: 1)
        case .green: UIColor(red: 0.40, green: 0.85, blue: 0.40, alpha: 1)
        case .blue: UIColor(red: 0.40, green: 0.72, blue: 1.00, alpha: 1)
        case .pink: UIColor(red: 1.00, green: 0.50, blue: 0.72, alpha: 1)
        case .orange: UIColor(red: 1.00, green: 0.62, blue: 0.20, alpha: 1)
        }
    }

    var color: Color { Color(uiColor: uiColor) }
}
