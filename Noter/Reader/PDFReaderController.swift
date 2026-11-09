import UIKit
import PDFKit
import PencilKit
import SwiftUI

extension PageGeometry {
    init(page: PDFPage) {
        self.init(box: page.bounds(for: .cropBox), rotation: page.rotation)
    }
}

/// PDF view with pencil highlighting.
/// * Finger: scroll, zoom, tap links — PDFKit's normal behaviour.
/// * Pencil: highlight. The stroke is snapped to whole words on the OCR'd text lines
///   live while you draw, and saved the moment you lift the pencil.
/// * Highlights, read-along, question marks, the pen preview and the "here it is" blink
///   are drawn on a per-page overlay view (not PDF annotations), so PDFKit never
///   re-renders the page for them.
final class PDFReaderController: UIView, UIGestureRecognizerDelegate, PDFPageOverlayViewProvider {
    let pdfView = PDFView()
    private let inkOverlay = UIView()
    private let inkLayer = CAShapeLayer()
    private let inkPath = UIBezierPath()
    private let pencil = PencilStrokeRecognizer(target: nil, action: nil)
    private lazy var readTap = UITapGestureRecognizer(target: self, action: #selector(handleReadTap(_:)))
    /// While scribbling, a finger tap that can't jump the voice shows "!" on the pen button.
    private lazy var hintTap = UITapGestureRecognizer(target: self, action: #selector(handleHintTap(_:)))
    private weak var session: DocumentSession?

    /// Overlays of the pages PDFKit is currently displaying, by page index.
    private var overlays: [Int: PDFPageOverlay] = [:]
    private var speechPhrase: SpeechPhrase?
    private var speech: SpeechState?
    private var preview: (page: Int, rects: [CGRect], color: UIColor)?
    private var pendingFlash: (page: Int, rects: [CGRect], date: Date)?

    private struct SpeechState {
        let page: Int
        let phrase: [CGRect]
        let word: CGRect?
    }
    private var hookedScrollViews = Set<ObjectIdentifier>()
    private var didInitialScroll = false
    private var ready = false

    private struct SpeechPhrase: Equatable {
        let slot: SlotKey
        let lower: Int
        let upper: Int
    }

    private struct Stroke {
        let page: PDFPage
        let pageIndex: Int
        let geometry: PageGeometry
        var lastViewPoint: CGPoint?
        var normPoints: [CGPoint] = []
        var processed = 0
        var half: Int?
        var hits: [StrokeHit] = []
        var range: ClosedRange<Int>?
        var erased = false
        var length: CGFloat = 0
    }
    private var stroke: Stroke?

    init(session: DocumentSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .systemGroupedBackground

        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        pdfView.backgroundColor = .systemGroupedBackground
        pdfView.pageOverlayViewProvider = self // must be set before the document
        pdfView.document = session.pdf
        addSubview(pdfView)

        inkOverlay.isUserInteractionEnabled = false
        inkLayer.fillColor = nil
        inkLayer.lineCap = .round
        inkLayer.lineJoin = .round
        inkOverlay.layer.addSublayer(inkLayer)
        addSubview(inkOverlay)

        pencil.addTarget(self, action: #selector(handlePencil(_:)))
        pdfView.addGestureRecognizer(pencil)

        readTap.allowedTouchTypes = fingerTouchTypes
        readTap.delegate = self
        pdfView.addGestureRecognizer(readTap)
        hintTap.allowedTouchTypes = fingerTouchTypes
        hintTap.delegate = self
        pdfView.addGestureRecognizer(hintTap)

        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(visiblePagesChanged), name: .PDFViewVisiblePagesChanged, object: pdfView)

        syncHighlights()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        pdfView.frame = bounds
        inkOverlay.frame = bounds
        inkLayer.frame = inkOverlay.bounds
        restrictPencilToHighlighting()
        if !didInitialScroll, bounds.width > 0, bounds.height > 0, let s = session {
            didInitialScroll = true
            let target = s.currentPage
            DispatchQueue.main.async { [weak self] in
                self?.goTo(page: target, rect: nil, force: true)
            }
        }
    }

    // MARK: - Pencil vs finger

    /// Makes every built-in PDFKit gesture (scrolling, zooming, text selection, link
    /// taps) finger-only, so a pencil touch can only ever highlight.
    private func restrictPencilToHighlighting() {
        func walk(_ v: UIView) {
            // The scribble canvas owns the pencil while scribbling: leave it alone.
            if v is PKCanvasView { return }
            for g in v.gestureRecognizers ?? []
            where g !== pencil && g !== readTap && g !== hintTap && !(g is UIHoverGestureRecognizer) {
                g.allowedTouchTypes = fingerTouchTypes
            }
            if let sv = v as? UIScrollView, hookedScrollViews.insert(ObjectIdentifier(sv)).inserted {
                sv.panGestureRecognizer.addTarget(self, action: #selector(userScrolled(_:)))
            }
            v.subviews.forEach(walk)
        }
        walk(pdfView)
    }

    @objc private func userScrolled(_ g: UIPanGestureRecognizer) {
        if g.state == .began || g.state == .changed { session?.noteUserActivity() }
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === readTap { return session?.speech.isActive ?? false }
        if g === hintTap {
            guard let s = session else { return false }
            return s.penMode == .scribble && !s.speech.isActive
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === readTap || g === hintTap
    }

    @objc private func handleHintTap(_ g: UITapGestureRecognizer) {
        session?.showScribbleHint()
    }

    // MARK: - Navigation

    @objc private func pageChanged() {
        guard ready, let s = session, s.viewMode == .pdf, let p = pdfView.currentPage else { return }
        s.setCurrentPage(s.pdf.index(for: p))
    }

    @objc private func visiblePagesChanged() {
        restrictPencilToHighlighting()
    }

    func goTo(page index: Int, rect: CGRect?, force: Bool = false) {
        guard let s = session, let page = s.pdf.page(at: index) else { return }
        if let rect {
            let pr = PageGeometry(page: page).pageRect(fromNormalized: rect)
            pdfView.go(to: pr.insetBy(dx: 0, dy: -max(pr.height * 6, 60)), on: page)
        } else if force || pdfView.currentPage.map({ s.pdf.index(for: $0) }) != index {
            pdfView.go(to: page)
        }
        ready = true
    }

    /// The word at the top of the screen (left page first on a two-page spread).
    func topAnchor() -> TextAnchor? {
        guard let s = session else { return nil }
        let top = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.minY + pdfView.safeAreaInsets.top + 16)
        guard let page = pdfView.page(for: top, nearest: true) else { return nil }
        let index = s.pdf.index(for: page)
        let n = PageGeometry(page: page).normalized(fromPage: pdfView.convert(top, to: page))
        guard let pages = s.logicalPages(index), !pages.isEmpty else {
            return TextAnchor(slot: SlotKey(pdfIndex: index, half: 0), token: 0)
        }
        // The page's top edge is on screen: start of the page.
        guard n.y > 0.02 else { return TextAnchor(slot: pages[0].slot, token: 0) }
        for lp in pages {
            if let line = lp.lines.first(where: { $0.rect.maxY >= n.y }), !line.tokens.isEmpty {
                return TextAnchor(slot: lp.slot, token: line.tokens.lowerBound)
            }
        }
        // Below all the text: the last line.
        let last = pages[pages.count - 1]
        return TextAnchor(slot: last.slot, token: max(last.tokens.count - 1, 0))
    }

    /// Scrolls so the line with this word is near the top of the screen.
    func scroll(to anchor: TextAnchor) {
        guard let s = session, let page = s.pdf.page(at: anchor.slot.pdfIndex) else { return }
        guard anchor.token > 0, let lp = s.logicalPage(anchor.slot), anchor.token < lp.tokens.count,
              let rect = lp.lineRects(for: anchor.token...anchor.token).first else {
            goTo(page: anchor.slot.pdfIndex, rect: nil, force: true)
            return
        }
        let pr = PageGeometry(page: page).pageRect(fromNormalized: rect)
        if page.rotation % 360 == 0 {
            // A destination puts its point at the top-left of the view.
            let context = 24 / max(pdfView.scaleFactor, 0.01)
            pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: kPDFDestinationUnspecifiedValue,
                                                                  y: pr.maxY + context)))
        } else {
            pdfView.go(to: pr.insetBy(dx: 0, dy: -pr.height * 2), on: page)
        }
        ready = true
    }

    // MARK: - Highlights

    /// Highlights changed: redraw them on the pages on screen (the others draw theirs
    /// when they appear).
    func syncHighlights() {
        for (index, overlay) in overlays { overlay.setHighlights(highlightItems(onPage: index)) }
    }

    private func highlightItems(onPage index: Int) -> [(rect: CGRect, color: UIColor, underline: Bool)] {
        guard let s = session else { return [] }
        return s.highlights(onPage: index).flatMap { h in
            h.rects.map { (rect: $0, color: h.color.uiColor, underline: h.isUnderlined) }
        }
    }

    private func showPreview(_ lp: LogicalPage, _ r: ClosedRange<Int>, onPage index: Int, color: HighlightColor) {
        let rects = lp.lineRects(for: r)
        if let old = preview, old.page != index { overlays[old.page]?.setPreview([], color: nil) }
        preview = (index, rects, color.uiColor)
        overlays[index]?.setPreview(rects, color: color.uiColor)
    }

    private func clearPreview() {
        if let old = preview { overlays[old.page]?.setPreview([], color: nil) }
        preview = nil
    }

    // MARK: - Page overlays

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let s = session else { return nil }
        let index = s.pdf.index(for: page)
        let overlay = overlays[index] ?? PDFPageOverlay(page: page, pdfView: view)
        overlays[index] = overlay
        if overlay.ink == nil {
            let ink = PageInkView(docID: s.info.id, pageIndex: index, pageSize: Self.displayedSize(page),
                                  undo: s.inkUndo)
            ink.settings = s.scribble
            ink.onActivity = { [weak s] in s?.noteUserActivity() }
            ink.onMessage = { [weak s] in s?.showToast($0) }
            overlay.attachInk(ink)
        }
        applyScribble(to: overlay)
        overlay.setHighlights(highlightItems(onPage: index))
        overlay.setMarks(markRects(onPage: index))
        if let speech, speech.page == index {
            overlay.setSpeech(phrase: speech.phrase, word: speech.word)
        } else {
            overlay.setSpeech(phrase: [], word: nil)
        }
        if let preview, preview.page == index {
            overlay.setPreview(preview.rects, color: preview.color)
        } else {
            overlay.setPreview([], color: nil)
        }
        DispatchQueue.main.async { [weak self] in self?.applyPendingFlash() }
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let s = session else { return }
        let index = s.pdf.index(for: page)
        (overlayView as? PDFPageOverlay)?.ink?.saveNow()
        if overlays[index] === overlayView { overlays[index] = nil }
    }

    // MARK: - Scribble

    /// The page's size as displayed (rotation applied), in points.
    private static func displayedSize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        return rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Pen mode, tool or scribble settings changed.
    func applyScribbleState() {
        guard let s = session else { return }
        let scribbling = s.penMode == .scribble
        // The pencil either highlights (our recognizer) or draws (PencilKit), never both.
        pencil.isEnabled = !scribbling
        if scribbling { cancelStroke() }
        pdfView.isInMarkupMode = scribbling
        for overlay in overlays.values { applyScribble(to: overlay) }
    }

    private func applyScribble(to overlay: PDFPageOverlay) {
        guard let s = session else { return }
        let scribbling = s.penMode == .scribble
        overlay.isUserInteractionEnabled = scribbling
        let tool: PKTool
        if s.tool == .erase {
            tool = PKEraserTool(s.scribble.eraser.pk)
        } else if s.scribble.lasso {
            tool = PKLassoTool()
        } else {
            tool = s.scribble.inkTool
        }
        overlay.ink?.setActive(scribbling, tool: tool, ruler: s.scribble.ruler)
    }

    func saveAllInk() {
        for overlay in overlays.values { overlay.ink?.saveNow() }
    }

    /// The page you're on (the most visible one).
    private var visiblePageIndex: Int? {
        guard let s = session, let page = pdfView.currentPage else { return nil }
        return s.pdf.index(for: page)
    }

    func tidyCurrentPage() {
        guard let index = visiblePageIndex, let ink = overlays[index]?.ink else {
            session?.showToast("Scroll to a page with handwriting")
            return
        }
        ink.tidy(all: true)
    }

    func clearCurrentPage() {
        guard let index = visiblePageIndex else { return }
        overlays[index]?.ink?.clear()
    }

    private func markRects(onPage index: Int) -> [CGRect] {
        guard let s = session, s.questions.markOnPages, let pages = s.logicalPages(index) else { return [] }
        return pages.flatMap { lp in s.questionRanges(lp).flatMap { lp.lineRects(for: $0) } }
    }

    /// Questions were found / toggled: redraw the marks on the visible pages.
    func refreshMarks() {
        for (index, overlay) in overlays { overlay.setMarks(markRects(onPage: index)) }
    }

    /// Boxes and blinks the given rects (normalized) on a page, once it's on screen.
    func flash(pageIndex: Int, rects: [CGRect]) {
        guard !rects.isEmpty else { return }
        pendingFlash = (pageIndex, rects, Date())
        // Give the jump a moment to scroll the page into place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.applyPendingFlash() }
    }

    private func applyPendingFlash() {
        guard let f = pendingFlash else { return }
        guard Date().timeIntervalSince(f.date) < 3 else {
            pendingFlash = nil
            return
        }
        guard let overlay = overlays[f.page], overlay.window != nil else { return }
        pendingFlash = nil
        overlay.flash(f.rects)
    }

    // MARK: - Pencil strokes

    @objc private func handlePencil(_ g: PencilStrokeRecognizer) {
        switch g.state {
        case .began:
            beginStroke(g)
            consume(g)
        case .changed:
            consume(g)
        case .ended:
            consume(g)
            endStroke()
        case .cancelled, .failed:
            cancelStroke()
        default:
            break
        }
    }

    private func beginStroke(_ g: PencilStrokeRecognizer) {
        guard let s = session, let first = g.points.first,
              let page = pdfView.page(for: first, nearest: true) else { return }
        s.noteUserActivity()
        stroke = Stroke(page: page, pageIndex: s.pdf.index(for: page), geometry: PageGeometry(page: page))
        inkPath.removeAllPoints()
        inkPath.move(to: first)
        let erasing = s.tool == .erase
        inkLayer.strokeColor = (erasing ? UIColor.systemGray : s.color.uiColor).withAlphaComponent(0.45).cgColor
        inkLayer.lineWidth = erasing ? 16 : 3
    }

    private func consume(_ g: PencilStrokeRecognizer) {
        guard var st = stroke, let s = session else { return }
        let pts = g.points
        guard st.processed < pts.count else { return }
        let pages = s.logicalPages(st.pageIndex)
        var newPoints: [CGPoint] = []

        for p in pts[st.processed...] {
            if let last = st.lastViewPoint { st.length += hypot(p.x - last.x, p.y - last.y) }
            st.lastViewPoint = p
            inkPath.addLine(to: p)
            let n = st.geometry.normalized(fromPage: pdfView.convert(p, to: st.page))
            st.normPoints.append(n)
            newPoints.append(n)
            if s.tool == .pen, let pages, let hit = PageHitTester.hit(n, in: pages, half: &st.half) {
                st.hits.append(hit)
            }
        }
        st.processed = pts.count
        inkLayer.path = inkPath.cgPath

        if s.tool == .pen {
            if let pages, let h = st.half, st.length > 6,
               let r = Snapper.range(for: st.hits, referenceWidth: pages[h].region.width), r != st.range {
                st.range = r
                showPreview(pages[h], r, onPage: st.pageIndex, color: s.color)
            }
        } else {
            let ids = s.highlightIDs(onPage: st.pageIndex, hitBy: newPoints)
            if !ids.isEmpty {
                s.removeHighlights(ids, registerUndo: !st.erased)
                st.erased = true
            }
        }
        stroke = st
    }

    private func endStroke() {
        inkLayer.path = nil
        guard let st = stroke, let s = session else {
            cancelStroke()
            return
        }
        stroke = nil
        guard s.tool == .pen, st.length > 6 else {
            clearPreview()
            return
        }
        if let pages = s.logicalPages(st.pageIndex) {
            Self.apply(st.normPoints, pages, s)
        } else {
            // The page hasn't been read yet: read it now, then apply the stroke.
            s.showToast("Reading this page…")
            let points = st.normPoints
            let index = st.pageIndex
            Task { @MainActor [weak s] in
                guard let s, await s.ocr.ensure(index) != nil, let pages = s.logicalPages(index) else { return }
                Self.apply(points, pages, s)
            }
        }
        clearPreview()
    }

    /// A finished highlighter stroke:
    /// * a tight loop around one word or a short phrase on one line marks it as a word to
    ///   define (a loop around more — a paragraph — just highlights what's inside);
    /// * a line drawn just under words underlines them (a definition, if a circled word
    ///   is waiting for one);
    /// * anything else highlights the words it went over.
    @MainActor
    private static func apply(_ points: [CGPoint], _ pages: [LogicalPage], _ s: DocumentSession) {
        guard !pages.isEmpty else { return }
        // The book page the stroke is on (the half of a two-page spread).
        let midX = points.map(\.x).reduce(0, +) / CGFloat(max(points.count, 1))
        let lp = pages.first { $0.region.minX <= midX && midX <= $0.region.maxX } ?? pages[0]
        let tokens = lp.tokens.enumerated().map { (index: $0.offset, rect: $0.element.rect) }
        switch StrokeShapeDetector.action(points, tokens: tokens) {
        case .term(let r): s.addTerm(on: lp, range: r); return
        case .highlight(let r): s.addHighlight(on: lp, range: r); return
        case .underline(let r): s.addHighlight(on: lp, range: r, underline: true); return
        case .none: break
        }
        if let sel = PageHitTester.selection(for: points, in: pages) {
            s.addHighlight(on: sel.page, range: sel.range)
        }
    }

    private func cancelStroke() {
        inkLayer.path = nil
        clearPreview()
        stroke = nil
    }

    // MARK: - Read aloud

    @objc private func handleReadTap(_ g: UITapGestureRecognizer) {
        guard let s = session, s.speech.isActive else { return }
        let p = g.location(in: pdfView)
        guard let page = pdfView.page(for: p, nearest: false) else { return }
        let index = s.pdf.index(for: page)
        guard let pages = s.logicalPages(index) else { return }
        let n = PageGeometry(page: page).normalized(fromPage: pdfView.convert(p, to: page))
        var half: Int?
        if let hit = PageHitTester.hit(n, in: pages, half: &half), let h = half {
            s.speech.play(from: SlotKey(pdfIndex: index, half: h), token: hit.token)
        }
    }

    /// Speechify-style read-along: a light tint on the sentence / phrase being read, and
    /// a darker fill with a solid underline (same color) on the word being spoken.
    func showSpeech(_ position: SpeechPosition?) {
        guard let s = session, let position, let lp = s.logicalPage(position.slot),
              let phrase = lp.phraseRange(containing: position.token),
              let page = s.pdf.page(at: position.pdfIndex) else {
            clearSpeech()
            return
        }
        let index = position.pdfIndex
        if let old = speech, old.page != index { overlays[old.page]?.setSpeech(phrase: [], word: nil) }
        let phraseRects = lp.lineRects(for: phrase)
        let word = lp.lineRects(for: position.token...position.token).first
        speech = SpeechState(page: index, phrase: phraseRects, word: word)
        overlays[index]?.setSpeech(phrase: phraseRects, word: word)

        // Scroll to follow when a new sentence starts.
        let key = SpeechPhrase(slot: position.slot, lower: phrase.lowerBound, upper: phrase.upperBound)
        guard key != speechPhrase else { return }
        speechPhrase = key
        let geometry = PageGeometry(page: page)
        let union = phraseRects.map { geometry.pageRect(fromNormalized: $0) }.reduce(nil) { (u: CGRect?, r) in
            u.map { $0.union(r) } ?? r
        }
        if let union { follow(union, on: page) }
    }

    private func clearSpeech() {
        if let old = speech { overlays[old.page]?.setSpeech(phrase: [], word: nil) }
        speech = nil
        speechPhrase = nil
    }

    /// Keeps the line being read on screen — unless you're scrolling or writing.
    private func follow(_ pageRect: CGRect, on page: PDFPage) {
        guard let s = session, s.viewMode == .pdf, stroke == nil, s.secondsSinceUserActivity > 4 else { return }
        let viewRect = pdfView.convert(pageRect, from: page)
        let safe = pdfView.bounds.insetBy(dx: 0, dy: pdfView.bounds.height * 0.12)
        if !safe.contains(viewRect) {
            let context = pdfView.bounds.height * 0.3 / max(pdfView.scaleFactor, 0.01)
            pdfView.go(to: pageRect.insetBy(dx: 0, dy: -context), on: page)
        }
    }
}

struct PDFReaderRepresentable: UIViewRepresentable {
    let session: DocumentSession

    func makeUIView(context: Context) -> PDFReaderController {
        let view = PDFReaderController(session: session)
        session.pdfController = view
        return view
    }

    func updateUIView(_ uiView: PDFReaderController, context: Context) {}
}
