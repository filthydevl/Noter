import UIKit
import PDFKit
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
/// * Read-along, key words, the pen preview and the "here it is" blink are drawn on a
///   per-page overlay view (not PDF annotations), so PDFKit never re-renders the page
///   for them.
final class PDFReaderController: UIView, UIGestureRecognizerDelegate, PDFPageOverlayViewProvider {
    let pdfView = PDFView()
    private let inkOverlay = UIView()
    private let inkLayer = CAShapeLayer()
    private let inkPath = UIBezierPath()
    private let pencil = PencilStrokeRecognizer(target: nil, action: nil)
    private lazy var readTap = UITapGestureRecognizer(target: self, action: #selector(handleReadTap(_:)))
    private weak var session: DocumentSession?

    private var rendered: [UUID: (highlight: Highlight, annotations: [PDFAnnotation])] = [:]
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
            for g in v.gestureRecognizers ?? [] where g !== pencil && g !== readTap && !(g is UIHoverGestureRecognizer) {
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
        g === readTap ? (session?.speech.isActive ?? false) : true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === readTap
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

    // MARK: - Highlights

    func syncHighlights() {
        guard let s = session else { return }
        var current: [UUID: Highlight] = [:]
        for h in s.highlights { current[h.id] = h }

        for (id, entry) in rendered where current[id] != entry.highlight {
            entry.annotations.forEach { $0.page?.removeAnnotation($0) }
            rendered[id] = nil
        }
        for h in s.highlights where rendered[h.id] == nil {
            guard let page = s.pdf.page(at: h.page) else { continue }
            let geo = PageGeometry(page: page)
            let annotations = h.rects.map {
                Self.highlightAnnotation(rect: $0, geometry: geo, color: h.color.uiColor.withAlphaComponent(0.5))
            }
            annotations.forEach { page.addAnnotation($0) }
            rendered[h.id] = (h, annotations)
        }
    }

    private static func highlightAnnotation(rect: CGRect, geometry: PageGeometry, color: UIColor) -> PDFAnnotation {
        // Hug the words: a touch wider than the text, slightly shorter than the OCR box,
        // so highlights on neighbouring lines never touch.
        let padded = rect.insetBy(dx: -0.002, dy: rect.height * 0.04)
        let a = PDFAnnotation(bounds: geometry.pageRect(fromNormalized: padded), forType: .highlight, withProperties: nil)
        a.color = color
        return a
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
        overlay.setKeywords(keywordRects(onPage: index))
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
        if overlays[index] === overlayView { overlays[index] = nil }
    }

    private func keywordRects(onPage index: Int) -> [CGRect] {
        guard let s = session, s.keywords.markOnPages, let pages = s.logicalPages(index) else { return [] }
        return pages.flatMap { lp in s.keywordRanges(lp).flatMap { lp.lineRects(for: $0) } }
    }

    /// Key words were found / toggled: redraw the marks on the visible pages.
    func refreshKeywordMarks() {
        for (index, overlay) in overlays { overlay.setKeywords(keywordRects(onPage: index)) }
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
            if s.tool == .highlight, let pages, let hit = PageHitTester.hit(n, in: pages, half: &st.half) {
                st.hits.append(hit)
            }
        }
        st.processed = pts.count
        inkLayer.path = inkPath.cgPath

        if s.tool == .highlight {
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
        guard s.tool == .highlight, st.length > 6 else {
            clearPreview()
            return
        }
        if let pages = s.logicalPages(st.pageIndex) {
            if let sel = PageHitTester.selection(for: st.normPoints, in: pages) {
                s.addHighlight(on: sel.page, range: sel.range)
            }
        } else {
            // The page hasn't been read yet: read it now, then apply the stroke.
            s.showToast("Reading this page…")
            let points = st.normPoints
            let index = st.pageIndex
            Task { @MainActor [weak s] in
                guard let s, await s.ocr.ensure(index) != nil, let pages = s.logicalPages(index),
                      let sel = PageHitTester.selection(for: points, in: pages) else { return }
                s.addHighlight(on: sel.page, range: sel.range)
            }
        }
        clearPreview()
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
