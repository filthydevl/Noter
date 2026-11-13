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
            // Scribbles are the same ink in both views: hand it over.
            if viewMode == .transcript {
                pdfController?.saveAllInk()
                transcriptController?.reloadInk()
            } else if viewMode == .pdf, let changed = transcriptController?.takeDirtyInkPages(), !changed.isEmpty {
                pdfController?.reloadInk(pages: changed)
            }
            syncPosition(from: oldValue)
        }
    }
    @Published var tool: PencilTool = .pen {
        didSet {
            if tool == .erase { scribble.lasso = false }
            transcriptController?.applyScribbleState()
            pdfController?.applyScribbleState()
        }
    }
    /// The pen button switches between highlighting and scribbling.
    @Published var penMode: PenMode = .highlight {
        didSet {
            pdfController?.applyScribbleState()
            transcriptController?.applyScribbleState()
            redoOffered = false
        }
    }
    /// Bumped when the ink undo manager changes (it isn't observable itself).
    @Published private(set) var inkUndoVersion = 0
    /// Redo is offered (beside Undo) for a few seconds after an undo.
    @Published private(set) var redoOffered = false
    private var redoHide: Task<Void, Never>?
    private var undoObservers: [NSObjectProtocol] = []

    /// After an undo or redo: show Redo for a few seconds.
    func offerRedo() {
        redoOffered = true
        redoHide?.cancel()
        redoHide = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.redoOffered = false
        }
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
    @Published private(set) var canRedo = false
    /// A side panel is open / the screen is narrow (portrait): jumping to a spot closes
    /// the panel so it doesn't cover it.
    var panelOpen = false
    var narrowLayout = false
    @Published private(set) var closePanelSignal = 0
    @Published private(set) var toast: String?
    @Published private(set) var speechPosition: SpeechPosition?
    @Published private(set) var labelsVersion = 0
    /// "Save PDF" is preparing the file.
    @Published private(set) var isSavingPDF = false

    let pdf: PDFDocument
    let ocr: OCRStore
    let speech: SpeechController
    let questions: QuestionIndex
    /// Highlight colors, their names, and auto-switch.
    let palette: ColorPalette
    /// The book's parts (headings), for the page slider.
    let outline: OutlineIndex
    /// Bracket Notes: pages transposed into your indented note style.
    let bracket: BracketNotes
    /// Key words you removed from the Key words list (remembered per document). Their
    /// highlights stay; they just aren't listed or offered as tags.
    @Published private(set) var removedKeywords: Set<String> = []
    /// Set right after you circle a word: the next highlight is its definition.
    @Published private(set) var pendingTerm: UUID? {
        didSet { if oldValue != pendingTerm { updateConfirm() } }
    }
    /// The underlines made so far for the circled word's definition (saved as one
    /// definition when you tap ✓).
    @Published private(set) var definitionParts: [UUID] = []
    /// Find in book (the search panel).
    private(set) lazy var search = BookSearch(session: self)
    weak var pdfController: PDFReaderController?
    weak var transcriptController: TranscriptController?

    private(set) var lastReadingMode: ViewMode = .pdf
    private var byPage: [Int: [Highlight]] = [:]
    private var layoutCache: [Int: [LogicalPage]] = [:]
    private var labels: [SlotKey: String] = [:]
    private var undoStack: [[Highlight]] = []
    private var redoStack: [[Highlight]] = []
    private var lastUserActivity = Date.distantPast
    private var toastTask: Task<Void, Never>?
    /// Bookkeeping after OCR pages finish is batched (see `pageReady`).
    private var readyFlush: Task<Void, Never>?
    /// Notes are saved a moment after you stop typing.
    private var noteSave: Task<Void, Never>?

    var pageCount: Int { pdf.pageCount }
    var secondsSinceUserActivity: TimeInterval { Date().timeIntervalSince(lastUserActivity) }

    init?(info: DocumentInfo) {
        guard let pdf = PDFDocument(url: Storage.pdfURL(info.id)), pdf.pageCount > 0 else { return nil }
        self.pdf = pdf
        var info = info
        info.lastOpened = Date()
        self.info = info
        // The same store the background reader used, if it was working on this book.
        let ocr = BackgroundOCR.shared.attach(info.id, pageCount: pdf.pageCount)
        self.ocr = ocr
        self.speech = SpeechController()
        self.questions = QuestionIndex(docID: info.id, ocr: ocr, mode: info.layoutMode)
        self.palette = ColorPalette(docID: info.id)
        self.outline = OutlineIndex(docID: info.id, ocr: ocr, mode: info.layoutMode)
        self.bracket = BracketNotes(docID: info.id)
        self.removedKeywords = Set(Storage.load([String].self, from: DocumentSession.removedKeywordsURL(info.id)) ?? [])
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
        bracket.session = self
        for name in [NSNotification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                     .NSUndoManagerDidRedoChange] {
            undoObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: inkUndo, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.inkUndoVersion &+= 1 }
                })
        }
        ocr.onPageReady = { [weak self] index in self?.pageReady(index) }
        questions.onChange = { [weak self] in self?.marksChanged() }
        scribble.onChange = { [weak self] in
            self?.pdfController?.applyScribbleState()
            self?.transcriptController?.applyScribbleState()
        }
        if questions.markOnPages { questions.start() }
        ocr.setFocus(currentPage)
        ocrDone = ocr.doneCount
        ocrUpgradeLeft = ocr.staleCount
        recomputeLabels()
        saveInfo()
        ocr.start()
        outline.start()
    }

    func close() {
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = []
        if readyFlush != nil {
            readyFlush?.cancel()
            flushPageReady()
        }
        pdfController?.saveAllInk()
        speech.stop()
        questions.stop()
        outline.stop()
        saveAll()
        // Keep reading the rest of the book's pages while you're in the library.
        BackgroundOCR.shared.detach(info.id)
    }

    /// The reader came back on screen without being rebuilt.
    func reopen() {
        _ = BackgroundOCR.shared.attach(info.id, pageCount: pdf.pageCount)
        ocr.onPageReady = { [weak self] index in self?.pageReady(index) }
        ocr.setFocus(currentPage)
        ocr.start()
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
        outline.reset(mode: mode)
        recomputeLabels()
        transcriptController?.reloadAll()
        HighlightExporter.export(self)
    }

    /// A page was (re-)recognized. What the page itself needs happens now; the
    /// whole-book bookkeeping (page numbers, saving, the highlights file) is batched, so
    /// a burst of pages doesn't keep the main thread busy.
    private func pageReady(_ index: Int) {
        layoutCache[index] = nil
        autoTagCache = nil
        ocrDone = ocr.doneCount
        ocrUpgradeLeft = ocr.staleCount
        reanchorHighlights(onPage: index)
        transcriptController?.pageBecameReady(index)
        questions.pageReady(index)
        outline.pageReady(index)
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
        bookOrder(highlights)
    }

    private func bookOrder(_ items: [Highlight]) -> [Highlight] {
        // Reading order: the page, its half, then where the highlight starts in the
        // page's text. Without the text yet: its top line (two highlights on the same
        // line, even a hair apart in height, go left to right).
        struct Key {
            let h: Highlight
            let page: Int
            let half: Int
            let start: Int?
            let top: CGRect
        }
        let keys = items.map { h -> Key in
            let side = self.half(of: h)
            let start = logicalPage(SlotKey(pdfIndex: h.page, half: side))?.range(of: h)?.lowerBound
            let top = h.rects.min { $0.minY < $1.minY } ?? .zero
            return Key(h: h, page: h.page, half: side, start: start, top: top)
        }
        return keys.sorted { a, b in
            if a.page != b.page { return a.page < b.page }
            if a.half != b.half { return a.half < b.half }
            if let x = a.start, let y = b.start, x != y { return x < y }
            let sameLine = abs(a.top.minY - b.top.minY) < max(min(a.top.height, b.top.height) * 0.5, 0.002)
            if !sameLine { return a.top.minY < b.top.minY }
            return a.top.minX < b.top.minX
        }
        .map(\.h)
    }

    /// Adds a highlight for a word range. Every stroke is its own highlight (nothing is
    /// merged, so one word can be a note of its own inside a longer highlight); the very
    /// same words in the same color twice are ignored. Right after you circle a word,
    /// the next highlight becomes its definition (an underline linked to the word).
    /// `underline`: you drew a line under the words.
    /// One stroke that ran over a page break: a highlight on each page, in the same
    /// color and shade (the color only moves on once, after the last part).
    func addHighlight(across parts: [(page: LogicalPage, range: ClosedRange<Int>)]) {
        let stroke = color
        for (n, part) in parts.enumerated() {
            color = stroke
            addHighlight(on: part.page, range: part.range, continuing: n > 0)
        }
    }

    // MARK: Tap a highlight, then add to it

    /// The highlight you tapped: your next stroke outside it is added to it.
    @Published private(set) var addingTo: UUID?
    private var addingTask: Task<Void, Never>?

    /// You tapped a word. On a highlight: it's picked, and the next line you highlight
    /// joins it (a stroke inside it is still a highlight of its own). Elsewhere: nothing
    /// is picked any more.
    func tapped(on lp: LogicalPage, token: Int) {
        guard penMode == .highlight, tool == .pen, pendingTerm == nil else { return }
        let under = highlights(onPage: lp.pdfIndex).compactMap { h -> (Highlight, ClosedRange<Int>)? in
            guard h.role == nil, let r = lp.range(of: h), r.contains(token) else { return nil }
            return (h, r)
        }
        // The innermost one, when highlights sit inside each other.
        guard let picked = under.min(by: { $0.1.count < $1.1.count }) else {
            if addingTo != nil { addingTo = nil }
            return
        }
        addingTo = picked.0.id
        showToast("Highlight a line to add it to this highlight")
        if viewMode == .transcript {
            transcriptController?.flash(slot: lp.slot, range: lp.textRange(for: picked.1))
        } else {
            pdfController?.flash(pageIndex: picked.0.page, rects: picked.0.rects)
        }
        addingTask?.cancel()
        addingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            self?.addingTo = nil
        }
    }

    /// Adds a stroke to the highlight you tapped: it grows to take the new words in
    /// (and the lines between). Not when the stroke is inside it, or on another page.
    private func addToPicked(on lp: LogicalPage, range: ClosedRange<Int>) -> Bool {
        guard let id = addingTo else { return false }
        addingTo = nil
        addingTask?.cancel()
        guard let index = highlights.firstIndex(where: { $0.id == id }), highlights[index].role == nil,
              let r = lp.range(of: highlights[index]) else { return false }
        guard !(range.lowerBound >= r.lowerBound && range.upperBound <= r.upperBound) else { return false }
        let union = min(r.lowerBound, range.lowerBound)...max(r.upperBound, range.upperBound)
        pushUndo()
        highlights[index].spans = lp.spans(for: union)
        highlights[index].rects = lp.lineRects(for: union)
        highlights[index].text = lp.string(for: union)
        highlightsChanged()
        return true
    }

    /// `start`: the word the stroke began on (for extending a highlight from inside it).
    func addHighlight(on lp: LogicalPage, range: ClosedRange<Int>, underline: Bool = false,
                      continuing: Bool = false, start: Int? = nil) {
        guard !lp.tokens.isEmpty, range.upperBound < lp.tokens.count, range.lowerBound >= 0 else { return }
        if pendingTerm == nil, !underline, addToPicked(on: lp, range: range) { return }
        if pendingTerm == nil, !underline, extendHighlight(on: lp, range: range, start: start) { return }
        var h = Highlight(
            id: UUID(), page: lp.pdfIndex, spans: lp.spans(for: range), rects: lp.lineRects(for: range),
            text: lp.string(for: range), color: color, created: Date())
        if let term = pendingTerm, let word = highlights.first(where: { $0.id == term }) {
            // Linked to the circled word (an ordinary highlight, in your pen's color):
            // keep collecting until ✓.
            _ = word
            h.role = "definition"
            h.termID = term
        } else {
            if underline { h.role = "underline" }
            // Manual colors: same color = same idea; a new shade for each new point.
            if !palette.autoSwitch {
                let last = highlights.last { $0.color == h.color && !$0.isTerm && !$0.isDefinition }
                // (The next page's part of the same stroke keeps the shade.)
                h.shade = last.map { (($0.shade ?? 0) + (continuing ? 0 : 1)) % HighlightColor.shadeCount } ?? 0
            }
        }
        let duplicate = highlights(onPage: lp.pdfIndex).contains {
            lp.range(of: $0) == range && $0.color == h.color && $0.role == h.role
        }
        guard !duplicate else { return }
        pushUndo()
        highlights.append(h)
        highlightsChanged()
        if h.isDefinition {
            definitionParts.append(h.id)
        } else if palette.autoSwitch {
            color = palette.next(after: color)
        }
    }

    /// You circled a word with the highlighter: it's highlighted in maroon, and your next
    /// highlight will be its definition.
    func addTerm(on lp: LogicalPage, range: ClosedRange<Int>) {
        guard !lp.tokens.isEmpty, range.upperBound < lp.tokens.count, range.lowerBound >= 0 else { return }
        // Circling another word while underlining: the definition so far is saved first.
        if pendingTerm != nil { confirmDefinition() }
        let h = Highlight(
            id: UUID(), page: lp.pdfIndex, spans: lp.spans(for: range), rects: lp.lineRects(for: range),
            text: lp.string(for: range), color: .maroon, created: Date(), role: "term")
        pushUndo()
        highlights.append(h)
        highlightsChanged()
        definitionParts = []
        pendingTerm = h.id
    }

    /// ✓: everything underlined since circling the word becomes its definition — one
    /// definition per page, its lines in reading order.
    func confirmDefinition() {
        guard pendingTerm != nil else { return }
        // Each linked highlight stays just what you highlighted (they used to be merged
        // into one stretch from the first to the last, as a "definition").
        let linked = definitionParts.count
        definitionParts = []
        pendingTerm = nil
        if linked > 0 { showToast("Linked") }
    }

    /// Lets the controllers show / hide the ✓ next to the circled word.
    private func updateConfirm() {
        let term = pendingTerm.flatMap { id in highlights.first { $0.id == id } }
        pdfController?.showConfirm(term)
        transcriptController?.showConfirm(term)
    }

    /// The word whose definition the next highlight will be.
    var pendingTermText: String? {
        pendingTerm.flatMap { id in highlights.first { $0.id == id } }.map { Highlight.keywordDisplay($0.text) }
    }

    /// ✕: stop without a definition (what you underlined for it is discarded).
    func cancelPendingTerm() {
        let parts = Set(definitionParts)
        definitionParts = []
        pendingTerm = nil
        if highlights.contains(where: { parts.contains($0.id) }) {
            pushUndo()
            highlights.removeAll { parts.contains($0.id) }
            highlightsChanged()
        }
    }

    func removeHighlights(_ ids: Set<UUID>, registerUndo: Bool = true) {
        guard !ids.isEmpty else { return }
        if registerUndo { pushUndo() }
        highlights.removeAll { ids.contains($0.id) }
        definitionParts.removeAll { ids.contains($0) }
        if let term = pendingTerm, ids.contains(term) {
            definitionParts = []
            pendingTerm = nil
        }
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

    func transcriptHighlightRanges(_ lp: LogicalPage) -> [TextHighlight] {
        highlights(onPage: lp.pdfIndex).compactMap { h in
            guard let r = lp.range(of: h) else { return nil }
            return TextHighlight(range: lp.textRange(for: r), color: h.uiColor, style: h.style)
        }
    }

    /// Highlights in book order, each circled word followed by its definition(s) — the
    /// way the highlights list and the exports show them.
    func groupedHighlights() -> [Highlight] {
        let sorted = sortedHighlights()
        let ids = Set(sorted.map(\.id))
        var definitions: [UUID: [Highlight]] = [:]
        for h in sorted where h.isDefinition {
            if let t = h.termID, ids.contains(t) { definitions[t, default: []].append(h) }
        }
        var out: [Highlight] = []
        for h in sorted {
            if h.isDefinition, let t = h.termID, ids.contains(t) { continue } // shown under its word
            out.append(h)
            if h.isTerm { out += definitions[h.id] ?? [] }
        }
        return out
    }

    /// Where a highlight is drawn on the PDF page. A definition covers its words from
    /// first to last (as the text view shows it), including definitions saved before
    /// they were joined that way.
    func displayRects(_ h: Highlight) -> [CGRect] {
        guard h.isDefinition, let pages = logicalPages(h.page) else { return h.rects }
        for lp in pages {
            if let r = lp.range(of: h) {
                let rects = lp.lineRects(for: r)
                return rects.isEmpty ? h.rects : rects
            }
        }
        return h.rects
    }

    /// The circled word a definition belongs to.
    func term(of h: Highlight) -> Highlight? {
        guard h.isDefinition, let t = h.termID else { return nil }
        return highlights.first { $0.id == t }
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
        redoStack.append(highlights)
        restore(previous)
    }

    /// Puts back what the last undo took away (until you change something new).
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(highlights)
        restore(next)
    }

    private func restore(_ state: [Highlight]) {
        var state = state
        // Undo is for highlights and tags; notes keep what you last typed.
        let notes = Dictionary(uniqueKeysWithValues: highlights.map { ($0.id, $0.note) })
        for i in state.indices {
            if let n = notes[state[i].id] { state[i].note = n }
        }
        highlights = state
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        // A definition in progress follows the undo too.
        let ids = Set(highlights.map(\.id))
        definitionParts.removeAll { !ids.contains($0) }
        if let term = pendingTerm, !ids.contains(term) {
            definitionParts = []
            pendingTerm = nil
        }
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
    /// In portrait an open side panel covers much of the page: close it before jumping.
    private func clearViewForJump() {
        guard panelOpen, narrowLayout else { return }
        closePanelSignal += 1
        panelOpen = false
        pdfController?.coveredRight = 64
    }

    func open(_ h: Highlight) {
        setCurrentPage(h.page)
        let mode = lastReadingMode
        viewMode = mode
        noteUserActivity() // don't let read-along scroll away from it
        clearViewForJump()
        if mode == .pdf {
            pdfController?.focus(page: h.page, rects: h.rects)
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
        clearViewForJump()
        guard let lp = logicalPage(slot), location.tokens.upperBound < lp.tokens.count else { return }
        if mode == .pdf {
            let rects = lp.lineRects(for: location.tokens)
            pdfController?.focus(page: slot.pdfIndex, rects: rects)
            pdfController?.flash(pageIndex: slot.pdfIndex, rects: rects)
        } else {
            transcriptController?.scroll(toPage: slot.pdfIndex, half: slot.half)
            transcriptController?.flash(slot: slot, range: lp.textRange(for: location.tokens))
        }
    }

    // MARK: - Key words (your one-word / short-phrase highlights) and tags

    /// Every word or short phrase you've highlighted, with where you highlighted it and
    /// the highlights you've tagged with it. Alphabetical.
    /// `includingRemoved`: also key words you took off the list (to show existing tags).
    func keywordEntries(includingRemoved: Bool = false) -> [KeywordEntry] {
        let all = allKeywordEntries()
        return includingRemoved ? all : all.filter { !removedKeywords.contains($0.id) }
    }

    private static func removedKeywordsURL(_ id: UUID) -> URL {
        Storage.folder(id).appendingPathComponent("removed-keywords.json")
    }

    /// Takes a key word off the Key words list. Its highlights stay on the pages.
    func removeKeyword(_ key: String) {
        removedKeywords.insert(key)
        Storage.save(Array(removedKeywords).sorted(), to: Self.removedKeywordsURL(info.id))
        HighlightExporter.export(self)
    }

    func restoreRemovedKeywords() {
        removedKeywords.removeAll()
        Storage.save([String](), to: Self.removedKeywordsURL(info.id))
        HighlightExporter.export(self)
    }

    private func allKeywordEntries() -> [KeywordEntry] {
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
            let linked = sorted.filter { $0.keywordKey != key && tagKeys(of: $0).contains(key) }
            return KeywordEntry(id: key, text: Highlight.keywordDisplay(latest.text), color: latest.color,
                                mentions: ms, linked: linked)
        }
        .sorted { $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending }
    }

    /// A stroke that runs into a highlight of the same color and carries on past it
    /// extends that highlight — it stays one highlight (two it bridges become one).
    /// Not when the stroke stays inside it (a word of its own within it), only touches
    /// the word next to it (that's a new highlight), or swallows a key word or a
    /// circled word / definition whole (they stay what they are). Returns whether it did.
    private func extendHighlight(on lp: LogicalPage, range: ClosedRange<Int>, start: Int? = nil) -> Bool {
        let latest = highlights.last
        // The pen's color — or, with auto switch, the color it just switched away from.
        func sameColor(_ ex: Highlight) -> Bool {
            ex.color == color || (palette.autoSwitch && ex.id == latest?.id && palette.next(after: ex.color) == color)
        }
        // A stroke that starts inside a highlight and moves up or down onto the line
        // above or below: the pen only grazes the starting line, so the stroke reads as
        // just the other line. Counting from the word it began on makes it an extension.
        var range = range
        if let start, start >= 0, start < lp.tokens.count,
           highlights(onPage: lp.pdfIndex).contains(where: { ex in
               ex.role == nil && sameColor(ex) && (lp.range(of: ex)?.contains(start) ?? false)
           }) {
            range = min(range.lowerBound, start)...max(range.upperBound, start)
        }
        let joined = highlights(onPage: lp.pdfIndex).compactMap { ex -> (Highlight, ClosedRange<Int>)? in
            guard ex.role == nil, let r = lp.range(of: ex) else { return nil }
            guard sameColor(ex) else { return nil }
            let overlaps = range.lowerBound <= r.upperBound && range.upperBound >= r.lowerBound
            let inside = range.lowerBound >= r.lowerBound && range.upperBound <= r.upperBound
            let around = range.lowerBound < r.lowerBound && range.upperBound > r.upperBound
            guard overlaps, !inside, !(around && ex.isKeyword) else { return nil }
            return (ex, r)
        }
        guard let first = joined.first?.0 else { return false }
        let lower = joined.map { $0.1.lowerBound }.reduce(range.lowerBound, min)
        let upper = joined.map { $0.1.upperBound }.reduce(range.upperBound, max)
        let union = lower...upper
        guard let index = highlights.firstIndex(where: { $0.id == first.id }) else { return false }
        pushUndo()
        var h = highlights[index]
        h.spans = lp.spans(for: union)
        h.rects = lp.lineRects(for: union)
        h.text = lp.string(for: union)
        // The others it bridged fold in: their tags and notes come along.
        let others = joined.dropFirst().map { $0.0 }
        if !others.isEmpty {
            var tags = h.tagKeys
            for o in others { tags += o.tagKeys.filter { !tags.contains($0) } }
            h.tags = tags.isEmpty ? nil : tags
            let notes = ([h] + others).compactMap(\.noteText)
            h.note = notes.isEmpty ? nil : notes.joined(separator: "\n")
            let ids = Set(others.map(\.id))
            highlights.removeAll { ids.contains($0.id) }
        }
        if let i = highlights.firstIndex(where: { $0.id == h.id }) { highlights[i] = h }
        highlightsChanged()
        return true
    }

    /// The analysis tags (cause, effect, premise…), each with the highlights tagged with
    /// it. `onlyUsed`: just the ones you've tagged something with.
    func analysisEntries(onlyUsed: Bool = false) -> [KeywordEntry] {
        let sorted = sortedHighlights()
        return AnalysisTag.allCases.compactMap { t in
            let linked = sorted.filter { $0.tagKeys.contains(t.key) }
            if onlyUsed && linked.isEmpty { return nil }
            return KeywordEntry(id: t.key, text: t.title, color: t.color, mentions: [], linked: linked,
                                symbol: t.symbol)
        }
    }

    /// Every tag a highlight can carry, by key: your key words and the analysis tags.
    func tagEntriesByKey() -> [String: KeywordEntry] {
        var all = Dictionary(uniqueKeysWithValues: keywordEntries(includingRemoved: true).map { ($0.id, $0) })
        for t in AnalysisTag.allCases {
            all[t.key] = KeywordEntry(id: t.key, text: t.title, color: t.color, mentions: [], linked: [],
                                      symbol: t.symbol)
        }
        return all
    }

    /// Adds or removes a key word tag on a highlight.
    func toggleTag(_ key: String, on id: UUID) {
        guard let i = highlights.firstIndex(where: { $0.id == id }) else { return }
        let tagged = tagKeys(of: highlights[i]).contains(key)
        var tags = highlights[i].tagKeys
        var untagged = highlights[i].untagged ?? []
        if tagged {
            tags.removeAll { $0 == key }
            // An automatic tag you take off stays off.
            if autoTags[id] == key, !untagged.contains(key) { untagged.append(key) }
        } else {
            untagged.removeAll { $0 == key }
            if autoTags[id] != key { tags.append(key) }
        }
        pushUndo()
        highlights[i].tags = tags.isEmpty ? nil : tags
        highlights[i].untagged = untagged.isEmpty ? nil : untagged
        highlightsChanged()
    }

    // MARK: - Save PDF

    /// A copy of the PDF with your work in it. `baked`: highlights and scribbles printed
    /// onto the pages. Otherwise: editable highlight annotations, no scribbles. Notes
    /// become sticky notes either way. Calls back with the file to share / save.
    /// The Text view as a PDF, with your scribbles beside the same words.
    func saveTextPDF(done: @escaping (URL) -> Void) {
        guard !isSavingPDF else { return }
        isSavingPDF = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let url = await TextPDFExport.export(self)
            self.isSavingPDF = false
            if let url {
                done(url)
            } else {
                self.showToast("No recognized text to save yet")
            }
        }
    }

    func savePDF(baked: Bool, done: @escaping (URL) -> Void) {
        guard !isSavingPDF else { return }
        isSavingPDF = true
        let info = self.info
        // Definitions printed from their first word to their last, as they're shown.
        let items = highlights.map { h -> Highlight in
            var h = h
            if h.isDefinition { h.rects = displayRects(h) }
            return h
        }
        let ink = baked ? AnnotatedPDFExport.inkImages(self) : nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let url = AnnotatedPDFExport.export(info: info, highlights: items, ink: ink)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isSavingPDF = false
                if let url {
                    done(url)
                } else {
                    self.showToast("Couldn't save the PDF")
                }
            }
        }
    }

    // MARK: - Notes

    /// Your note on a highlight (typed in the Notes panel). Saved shortly after you
    /// stop typing.
    func setNote(_ text: String, on id: UUID) {
        guard let i = highlights.firstIndex(where: { $0.id == id }), (highlights[i].note ?? "") != text else { return }
        highlights[i].note = text.isEmpty ? nil : text
        rebuildIndex()
        noteSave?.cancel()
        noteSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.noteSave = nil
            Storage.save(self.highlights, to: Storage.highlightsURL(self.info.id))
            HighlightExporter.export(self)
        }
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
        redoStack = []
        canRedo = false
    }

    private func rebuildIndex() {
        byPage = Dictionary(grouping: highlights, by: \.page)
        autoTagCache = nil
    }

    /// Highlight → the key word it's automatically tagged with. Worked out when needed
    /// (the order of a spread's halves needs its page read).
    private var autoTags: [UUID: String] {
        if let cached = autoTagCache { return cached }
        let tags = computeAutoTags()
        autoTagCache = tags
        return tags
    }
    private var autoTagCache: [UUID: String]?

    /// A key word (a name, word or phrase of up to 3 words) tags the highlights that
    /// follow it in the same color (any shade of it): "Venustiano Carranza" in green,
    /// then green lines about him. The run ends at a highlight of another color, at the
    /// next key word, or after a page with no highlights.
    private func computeAutoTags() -> [UUID: String] {
        var out: [UUID: String] = [:]
        var run: (key: String, color: HighlightColor)?
        var lastPage = Int.min
        for h in sortedHighlights() {
            if lastPage != Int.min, h.page - lastPage > 1 { run = nil }
            lastPage = h.page
            if h.isKeyword {
                let key = h.keywordKey
                run = key.isEmpty ? nil : (key, h.color)
                continue
            }
            guard let r = run, h.color == r.color else {
                run = nil
                continue
            }
            out[h.id] = r.key
        }
        return out
    }

    /// The key words a highlight is tagged with: yours plus the automatic one.
    func tagKeys(of h: Highlight) -> [String] {
        var keys = h.tagKeys
        if let auto = autoTags[h.id], !keys.contains(auto), !(h.untagged ?? []).contains(auto) {
            keys.append(auto)
        }
        return keys
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

    func readerScrollBegan() {
        noteUserActivity()
    }

    /// The sentence at the top of the PDF / Text view, for Bracket Notes to follow.
    let readerPosition = ReaderPosition()
    private var lastPositionReport = Date.distantPast
    private var positionReportPending = false

    /// The reader scrolled: report where it is now — only while Bracket Notes is open,
    /// and at most a few times a second.
    func readerMoved(now: Bool = false) {
        guard bracket.isShowing else { return }
        let wait = 0.15 - Date().timeIntervalSince(lastPositionReport)
        if wait > 0, !now {
            guard !positionReportPending else { return }
            positionReportPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.positionReportPending = false
                self?.readerMoved(now: true)
            }
            return
        }
        lastPositionReport = Date()
        let anchor = viewMode == .transcript ? transcriptController?.topAnchor() : pdfController?.topAnchor()
        if let anchor, anchor != readerPosition.anchor { readerPosition.anchor = anchor }
    }

    /// You touched, highlighted or wrote beside a word: Bracket Notes goes to its
    /// sentence (while it's open).
    func readerTouched(_ anchor: TextAnchor) {
        guard bracket.isShowing else { return }
        readerPosition.touched = .init(anchor: anchor, count: (readerPosition.touched?.count ?? 0) + 1)
    }

    // MARK: - Citations

    /// Shows the sheet where the book's details (author, title, publisher…) are kept.
    @Published var showSourceDetails = false
    private(set) lazy var source: SourceInfo = SourceInfo.load(for: self)

    func saveSource(_ s: SourceInfo) {
        source = s
        Storage.save(s, to: SourceInfo.url(info.id))
    }

    /// The page number printed in the book for a highlight (nil: none recognized).
    func printedPage(for h: Highlight) -> String? {
        labels[SlotKey(pdfIndex: h.page, half: half(of: h))]
    }

    /// Copies a citation for a highlight (formatted text, with a plain copy for apps
    /// that don't take formatting).
    func cite(_ h: Highlight, style: CitationStyle, withQuote: Bool) {
        guard source.isUsable else {
            showSourceDetails = true
            showToast("Fill in the book's details once, then cite")
            return
        }
        let page = printedPage(for: h)
        let text = Citation.make(source, page: page, style: style, quote: withQuote ? h.text : nil)
        Citation.copy(text)
        showToast(page == nil
                  ? "Copied — no printed page number was found, so add it yourself"
                  : "Copied \(style.title) citation, p. \(page ?? "")")
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

extension Highlight {
    /// The highlight's color in its shade.
    var uiColor: UIColor { color.uiColor(shade: shade) }
    var displayColor: Color { Color(uiColor: uiColor) }
    var hex: String {
        guard let shade, shade % HighlightColor.shadeCount != 0 else { return color.hex }
        return color.uiColor(shade: shade).hexString6
    }
}

extension UIColor {
    /// "#RRGGBB"
    var hexString6: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

extension HighlightColor {
    /// Variations of each color: the color, deeper, lighter, and slightly warmer.
    static let shadeCount = 4

    func uiColor(shade: Int?) -> UIColor {
        let base = uiColor
        guard let shade, shade % Self.shadeCount != 0 else { return base }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard base.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return base }
        switch shade % Self.shadeCount {
        case 1: return UIColor(hue: h, saturation: min(s * 1.15, 1), brightness: b * 0.78, alpha: a)
        case 2: return UIColor(hue: h, saturation: s * 0.5, brightness: min(b * 1.08 + 0.06, 1), alpha: a)
        default:
            let warmer = (h + (h > 0.5 ? -0.035 : 0.035)).truncatingRemainder(dividingBy: 1)
            return UIColor(hue: warmer < 0 ? warmer + 1 : warmer, saturation: min(s * 1.05, 1),
                           brightness: b * 0.9, alpha: a)
        }
    }

    var uiColor: UIColor {
        switch rawValue {
        case "yellow": UIColor(red: 1.00, green: 0.84, blue: 0.10, alpha: 1)
        case "green": UIColor(red: 0.40, green: 0.85, blue: 0.40, alpha: 1)
        case "blue": UIColor(red: 0.40, green: 0.72, blue: 1.00, alpha: 1)
        case "pink": UIColor(red: 1.00, green: 0.50, blue: 0.72, alpha: 1)
        case "orange": UIColor(red: 1.00, green: 0.62, blue: 0.20, alpha: 1)
        case "maroon": UIColor(red: 0.62, green: 0.12, blue: 0.20, alpha: 1)
        default: UIColor(hex: rawValue) ?? UIColor(red: 1.00, green: 0.84, blue: 0.10, alpha: 1)
        }
    }

    var color: Color { Color(uiColor: uiColor) }

    /// For the PDF exports.
    var hex: String {
        switch rawValue {
        case "yellow": "#FFD61A"
        case "green": "#66D966"
        case "blue": "#66B8FF"
        case "pink": "#FF80B8"
        case "orange": "#FF9E33"
        case "maroon": "#9E1F33"
        default: rawValue
        }
    }
}
