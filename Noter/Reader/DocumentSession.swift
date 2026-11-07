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
            syncPosition(from: oldValue)
        }
    }
    @Published var tool: PencilTool = .pen {
        didSet {
            if tool == .erase { scribble.lasso = false }
            pdfController?.applyScribbleState()
        }
    }
    /// The pen button switches between highlighting and scribbling.
    @Published var penMode: PenMode = .highlight {
        didSet { pdfController?.applyScribbleState() }
    }
    /// Briefly true when you tap the page while scribbling (shows "!" on the pen button).
    @Published private(set) var scribbleHint = false
    /// Scribble tool settings (pen type, size, color…).
    let scribble = ScribbleSettings()
    /// One undo history for all scribbling, across pages.
    let inkUndo = UndoManager()
    private var hintTask: Task<Void, Never>?
    @Published var color: HighlightColor {
        didSet { UserDefaults.standard.set(color.rawValue, forKey: "noter.highlightColor") }
    }
    @Published var transcriptFontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(transcriptFontSize), forKey: "noter.fontSize")
            transcriptController?.reloadAll()
        }
    }
    /// Text view reading options (theme, font, spacing, margins, alignment).
    @Published var textAppearance = TextAppearance.load() {
        didSet {
            guard oldValue != textAppearance else { return }
            textAppearance.save()
            transcriptController?.appearanceChanged()
        }
    }
    @Published private(set) var ocrDone = 0
    /// Pages still to be re-read by the improved (second-pass) recognizer.
    @Published private(set) var ocrUpgradeLeft = 0
    @Published private(set) var currentPage = 0
    @Published private(set) var canUndo = false
    @Published private(set) var toast: String?
    @Published private(set) var speechPosition: SpeechPosition?
    @Published private(set) var labelsVersion = 0

    let pdf: PDFDocument
    let ocr: OCRStore
    let speech: SpeechController
    let questions: QuestionIndex
    /// Find in book (the search panel).
    private(set) lazy var search = BookSearch(session: self)
    weak var pdfController: PDFReaderController?
    weak var transcriptController: TranscriptController?

    private(set) var lastReadingMode: ViewMode = .pdf
    private var byPage: [Int: [Highlight]] = [:]
    private var layoutCache: [Int: [LogicalPage]] = [:]
    private var labels: [SlotKey: String] = [:]
    private var undoStack: [[Highlight]] = []
    private var lastUserActivity = Date.distantPast
    private var toastTask: Task<Void, Never>?
    /// Bookkeeping after OCR pages finish is batched (see `pageReady`).
    private var readyFlush: Task<Void, Never>?

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
        self.questions = QuestionIndex(docID: info.id, ocr: ocr, mode: info.layoutMode)
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
        questions.onChange = { [weak self] in self?.marksChanged() }
        scribble.onChange = { [weak self] in self?.pdfController?.applyScribbleState() }
        if questions.markOnPages { questions.start() }
        ocr.setFocus(currentPage)
        ocrDone = ocr.doneCount
        ocrUpgradeLeft = ocr.staleCount
        recomputeLabels()
        saveInfo()
        ocr.start()
    }

    func close() {
        if readyFlush != nil {
            readyFlush?.cancel()
            flushPageReady()
        }
        pdfController?.saveAllInk()
        speech.stop()
        questions.stop()
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
        search.invalidate()
        questions.reset(mode: mode)
        recomputeLabels()
        transcriptController?.reloadAll()
        HighlightExporter.export(self)
    }

    /// A page was (re-)recognized. What the page itself needs happens now; the
    /// whole-book bookkeeping (page numbers, saving, the highlights file) is batched, so
    /// a burst of pages doesn't keep the main thread busy.
    private func pageReady(_ index: Int) {
        layoutCache[index] = nil
        ocrDone = ocr.doneCount
        ocrUpgradeLeft = ocr.staleCount
        reanchorHighlights(onPage: index)
        transcriptController?.pageBecameReady(index)
        questions.pageReady(index)
        search.invalidate(index)
        guard readyFlush == nil else { return }
        readyFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self?.flushPageReady()
        }
    }

    private func flushPageReady() {
        readyFlush = nil
        info.ocrPagesDone = ocrDone
        saveInfo()
        recomputeLabels()
        pdfController?.refreshMarks()
        if ocr.isComplete { HighlightExporter.export(self) }
    }

    /// A page was (re-)recognized: its words may be numbered differently now, so point
    /// each highlight on it at the words that sit under its rectangles.
    private func reanchorHighlights(onPage index: Int) {
        guard byPage[index]?.isEmpty == false, let page = ocr.page(index) else { return }
        var changed = false
        for i in highlights.indices where highlights[i].page == index {
            let areas = highlights[i].rects.map { $0.insetBy(dx: -0.002, dy: -$0.height * 0.2) }
            var spans: [TokenSpan] = []
            for (li, line) in page.lines.enumerated() {
                for (ti, t) in line.k.enumerated()
                where areas.contains(where: { $0.contains(CGPoint(x: t.r.midX, y: t.r.midY)) }) {
                    if var last = spans.last, last.line == li, last.end + 1 == ti {
                        last.end = ti
                        spans[spans.count - 1] = last
                    } else {
                        spans.append(TokenSpan(line: li, start: ti, end: ti))
                    }
                }
            }
            if !spans.isEmpty, spans != highlights[i].spans {
                highlights[i].spans = spans
                changed = true
            }
        }
        guard changed else { return }
        rebuildIndex()
        Storage.save(highlights, to: Storage.highlightsURL(info.id))
        transcriptController?.refreshHighlights()
    }

    func readingStartSlot() -> SlotKey {
        if viewMode == .transcript, let slot = transcriptController?.topVisibleSlot() { return slot }
        return SlotKey(pdfIndex: currentPage, half: 0)
    }

    /// You switched between PDF and Text: open the other view on the same line — the
    /// one being read aloud, or else the one at the top of the screen you came from.
    private func syncPosition(from old: ViewMode) {
        var anchor: TextAnchor?
        if speech.isActive, let p = speechPosition, secondsSinceUserActivity > 4 {
            anchor = TextAnchor(slot: p.slot, token: p.token)
        } else {
            switch old {
            case .pdf: anchor = pdfController?.topAnchor()
            case .transcript: anchor = transcriptController?.topAnchor()
            case .highlights: anchor = nil
            }
        }
        let a = anchor ?? TextAnchor(slot: SlotKey(pdfIndex: currentPage, half: 0), token: 0)
        setCurrentPage(a.slot.pdfIndex)
        switch viewMode {
        case .pdf: pdfController?.scroll(to: a)
        case .transcript: transcriptController?.scroll(to: a)
        case .highlights: break
        }
    }

    /// The page slider: jump the view you're in to a PDF page.
    func goToPage(_ index: Int) {
        let i = max(0, min(index, pageCount - 1))
        noteUserActivity()
        setCurrentPage(i)
        switch viewMode {
        case .pdf: pdfController?.goTo(page: i, rect: nil)
        case .transcript: transcriptController?.scroll(toPage: i)
        case .highlights: break
        }
    }

    /// The bookmark button on the player: back to the sentence being read, in the view
    /// you're in, and keep following it.
    func showReadingPosition() {
        guard let p = speechPosition, let lp = logicalPage(p.slot), p.token < lp.tokens.count else {
            showToast(speech.isActive ? "Finding the reading position…" : "Not reading right now")
            return
        }
        lastUserActivity = .distantPast // resume follow-along
        setCurrentPage(p.pdfIndex)
        let range = lp.phraseRange(containing: p.token) ?? (p.token...p.token)
        if viewMode == .transcript {
            transcriptController?.scroll(to: TextAnchor(slot: p.slot, token: range.lowerBound))
            transcriptController?.flash(slot: p.slot, range: lp.textRange(for: range))
        } else {
            let rects = lp.lineRects(for: range)
            pdfController?.goTo(page: p.pdfIndex, rect: rects.first)
            pdfController?.flash(pageIndex: p.pdfIndex, rects: rects)
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

    /// Label above a page in the text view: printed page number, PDF page, and the
    /// running header (none of which is read aloud).
    func headerLabel(for slot: SlotKey) -> String {
        var text: String
        if let l = labels[slot] {
            let side = halfCount(slot.pdfIndex) > 1 ? (slot.half == 0 ? " left" : " right") : ""
            text = "Page \(l)   ·   PDF \(slot.pdfIndex + 1)\(side)"
        } else {
            text = label(for: slot)
        }
        if let running = layoutCache[slot.pdfIndex]?.first(where: { $0.half == slot.half })?.runningHeader {
            text += "   ·   " + running
        }
        return text
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
        // Keep the key word tags of any highlight this one swallows.
        var tags: [String] = []
        for old in highlights where absorbed.contains(old.id) {
            for t in old.tagKeys where !tags.contains(t) { tags.append(t) }
        }
        let h = Highlight(
            id: UUID(), page: lp.pdfIndex, spans: lp.spans(for: merged), rects: lp.lineRects(for: merged),
            text: lp.string(for: merged), color: color, created: Date(), tags: tags.isEmpty ? nil : tags)
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

    /// Apple Pencil double-tap / squeeze: highlighter ↔ scribble pen.
    func pencilButton() {
        tool = .pen
        penMode = penMode == .highlight ? .scribble : .highlight
        scribble.lasso = false
        showToast(penMode == .scribble ? "Scribble pen" : "Highlighter")
    }

    /// Pen ↔ eraser.
    func toggleTool() {
        tool = tool == .pen ? .erase : .pen
        showToast(tool == .erase ? "Eraser" : (penMode == .scribble ? "Scribble pen" : "Highlighter"))
    }

    /// The pen button: back to the pen from the eraser, otherwise highlighter ↔ scribble.
    func togglePen() {
        if tool == .erase {
            tool = .pen
        } else {
            penMode = penMode == .highlight ? .scribble : .highlight
            scribble.lasso = false
        }
        showToast(penMode == .scribble ? "Scribble" : "Highlighter")
        if penMode == .scribble, viewMode != .pdf { showToast("Scribble draws on the PDF view") }
    }

    /// You tapped the page while scribbling and the tap had nothing to do: flash a "!"
    /// on the pen button (tap it to switch back to the highlighter).
    func showScribbleHint() {
        scribbleHint = true
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.scribbleHint = false
        }
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

    /// Jumps to a spot in the book (a question…) and blinks a box around it.
    func open(_ location: TextLocation) {
        let slot = location.slot
        setCurrentPage(slot.pdfIndex)
        let mode = lastReadingMode
        viewMode = mode
        noteUserActivity()
        guard let lp = logicalPage(slot), location.tokens.upperBound < lp.tokens.count else { return }
        if mode == .pdf {
            let rects = lp.lineRects(for: location.tokens)
            pdfController?.goTo(page: slot.pdfIndex, rect: rects.first)
            pdfController?.flash(pageIndex: slot.pdfIndex, rects: rects)
        } else {
            transcriptController?.scroll(toPage: slot.pdfIndex, half: slot.half)
            transcriptController?.flash(slot: slot, range: lp.textRange(for: location.tokens))
        }
    }

    // MARK: - Key words (your one-word / short-phrase highlights) and tags

    /// Every word or short phrase you've highlighted, with where you highlighted it and
    /// the highlights you've tagged with it. Alphabetical.
    func keywordEntries() -> [KeywordEntry] {
        let sorted = sortedHighlights()
        var order: [String] = []
        var mentions: [String: [Highlight]] = [:]
        for h in sorted where h.isKeyword {
            let key = h.keywordKey
            guard !key.isEmpty else { continue }
            if mentions[key] == nil { order.append(key) }
            mentions[key, default: []].append(h)
        }
        return order.compactMap { key -> KeywordEntry? in
            guard let ms = mentions[key], let latest = ms.max(by: { $0.created < $1.created }) else { return nil }
            let linked = sorted.filter { $0.keywordKey != key && $0.tagKeys.contains(key) }
            return KeywordEntry(id: key, text: Highlight.keywordDisplay(latest.text), color: latest.color,
                                mentions: ms, linked: linked)
        }
        .sorted { $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending }
    }

    /// Adds or removes a key word tag on a highlight.
    func toggleTag(_ key: String, on id: UUID) {
        guard let i = highlights.firstIndex(where: { $0.id == id }) else { return }
        var tags = highlights[i].tagKeys
        if let j = tags.firstIndex(of: key) {
            tags.remove(at: j)
        } else {
            tags.append(key)
        }
        pushUndo()
        highlights[i].tags = tags.isEmpty ? nil : tags
        highlightsChanged()
    }

    // MARK: - Questions

    /// Question token ranges to mark on a book page (empty unless "Mark on pages" is on).
    func questionRanges(_ lp: LogicalPage) -> [ClosedRange<Int>] {
        guard questions.markOnPages else { return [] }
        return questions.ranges(on: lp.slot).filter { $0.upperBound < lp.tokens.count }
    }

    func questionTextRanges(_ lp: LogicalPage) -> [NSRange] {
        questionRanges(lp).map { lp.textRange(for: $0) }
    }

    private func marksChanged() {
        pdfController?.refreshMarks()
        transcriptController?.refreshMarks()
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

    /// For the PDF exports.
    var hex: String {
        switch self {
        case .yellow: "#FFD61A"
        case .green: "#66D966"
        case .blue: "#66B8FF"
        case .pink: "#FF80B8"
        case .orange: "#FF9E33"
        }
    }
}
