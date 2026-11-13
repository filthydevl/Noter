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
    /// Double-tap a word: read aloud from there (PDFKit's double-tap zoom is off).
    private lazy var readDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleReadDoubleTap(_:)))
    /// While scribbling, a finger tap that can't jump the voice shows "!" on the pen button.
    private lazy var hintTap = UITapGestureRecognizer(target: self, action: #selector(handleHintTap(_:)))
    /// A tap (finger or pencil) on the ✓ next to a circled word. Caught here because PDFKit
    /// only passes touches to things drawn on a page in markup mode.
    private lazy var confirmTap = UITapGestureRecognizer(target: self, action: #selector(handleConfirmTap(_:)))
    private weak var session: DocumentSession?

    /// Overlays of the pages PDFKit is currently displaying, by page index.
    private var overlays: [Int: PDFPageOverlay] = [:]
    private var speechPhrase: SpeechPhrase?
    private var speech: SpeechState?
    private var preview: (page: Int, rects: [CGRect], color: UIColor)?
    private var pendingFlash: (page: Int, rects: [CGRect], date: Date)?
    /// The circled word whose definition is being underlined (its ✓ is shown next to it).
    private var confirm: (page: Int, rect: CGRect)?

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
        // Pages run edge to edge: no strips of background beside them.
        pdfView.pageBreakMargins = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
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
        pencil.ignoresTouch = { [weak self] p in self?.confirmHit(p) ?? false }
        pdfView.addGestureRecognizer(pencil)

        confirmTap.delegate = self
        pdfView.addGestureRecognizer(confirmTap)

        readTap.allowedTouchTypes = fingerTouchTypes
        readTap.delegate = self
        pdfView.addGestureRecognizer(readTap)
        readDoubleTap.numberOfTapsRequired = 2
        readDoubleTap.allowedTouchTypes = fingerTouchTypes
        readDoubleTap.delegate = self
        pdfView.addGestureRecognizer(readDoubleTap)
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
        // While the iPad rotates the page area can be squeezed to nothing for a moment:
        // PDFKit then fits the page at a zoom of 0 / NaN and draws garbage (the flood of
        // CoreGraphics "NaN" / "no current point" messages). Keep the last real size.
        guard bounds.width >= 2, bounds.height >= 2, bounds.isFiniteRect else { return }
        // A page that filled the width keeps filling it when the page area changes
        // size (a list opening or closing, rotating): never bars beside it afterwards.
        let oldWidth = pdfView.bounds.width
        let refit = abs(oldWidth - bounds.width) > 1 && fillsWidth(oldWidth)
        var place: CGFloat?
        if refit, let sv = scrollView, sv.contentSize.height > 1 {
            place = (sv.contentOffset.y + sv.adjustedContentInset.top) / sv.contentSize.height
        }
        pdfView.frame = bounds
        if refit { fitWidth(keeping: place) }
        repairBrokenZoom()
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
            // The scribble canvas and the shape layer own the pencil while scribbling, and
            // the ✓ takes pencil taps: leave them alone.
            if v is PKCanvasView || v is ShapeOverlayView || v is RoomyButton { return }
            for g in v.gestureRecognizers ?? []
            where g !== pencil && g !== readTap && g !== hintTap && g !== confirmTap && g !== readDoubleTap
                && !(g is UIHoverGestureRecognizer) {
                g.allowedTouchTypes = fingerTouchTypes
                // PDFKit's double-tap zoom: a double tap reads aloud instead (pinch still zooms).
                if let tap = g as? UITapGestureRecognizer, tap.numberOfTapsRequired == 2 { tap.isEnabled = false }
            }
            if let sv = v as? UIScrollView, hookedScrollViews.insert(ObjectIdentifier(sv)).inserted {
                sv.panGestureRecognizer.addTarget(self, action: #selector(userScrolled(_:)))
            }
            v.subviews.forEach(walk)
        }
        walk(pdfView)
    }

    @objc private func userScrolled(_ g: UIPanGestureRecognizer) {
        if g.state == .began {
            session?.readerScrollBegan()
        } else if g.state == .changed {
            session?.noteUserActivity()
        }
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === readTap { return session?.speech.isActive ?? false }
        if g === confirmTap { return confirmHit(g.location(in: pdfView)) }
        if g === hintTap {
            guard let s = session else { return false }
            return s.penMode == .scribble && !s.speech.isActive
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === readTap || g === hintTap || g === confirmTap || g === readDoubleTap
    }

    /// Whether a point in the PDF view is on (or right next to) a ✓.
    private func confirmHit(_ point: CGPoint) -> Bool {
        overlays.values.contains { o in
            guard o.window != nil, let f = o.confirmHitFrame else { return false }
            return o.convert(f, to: pdfView).contains(point)
        }
    }

    @objc private func handleConfirmTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        session?.confirmDefinition()
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
        repairBrokenZoom()
        restrictPencilToHighlighting()
    }

    func goTo(page index: Int, rect: CGRect?, force: Bool = false) {
        guard let s = session, let page = s.pdf.page(at: index) else { return }
        if let rect, rect.isFiniteRect, PageGeometry(page: page).pageRect(fromNormalized: rect).isFiniteRect {
            let pr = PageGeometry(page: page).pageRect(fromNormalized: rect)
            pdfView.go(to: pr.insetBy(dx: 0, dy: -max(pr.height * 6, 60)), on: page)
        } else if force || pdfView.currentPage.map({ s.pdf.index(for: $0) }) != index {
            pdfView.go(to: page)
        }
        ready = true
    }

    /// Zooms in on a spot (normalized rects on a page) and centers it on screen: the
    /// highlight's lines fill most of the width, without it running off the screen.
    func focus(page index: Int, rects: [CGRect], retry: Bool = true) {
        let rects = rects.filter { $0.isFiniteRect && !$0.isNull }
        guard let s = session, let page = s.pdf.page(at: index), let first = rects.first else {
            goTo(page: index, rect: nil)
            return
        }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        let pr = PageGeometry(page: page).pageRect(fromNormalized: union)
        let size = Self.displayedSize(page)
        let view = visibleArea
        guard view.width > 10, view.height > 10, size.width > 1 else {
            // The PDF view is only just appearing: jump now, zoom once it has a size.
            goTo(page: index, rect: first)
            if retry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.focus(page: index, rects: rects, retry: false)
                }
            }
            return
        }
        // The highlight's size on the page, in page points (rotation applied).
        let width = union.width * size.width, height = union.height * size.height
        // Right in on the quote: it fills the width you can see (and at most ~40% of the
        // height), never smaller than the page fitted to the screen's width.
        let fitScreen = pdfView.bounds.inset(by: pdfView.safeAreaInsets).width / size.width
        var scale = view.width * 0.92 / max(width, 1)
        scale = min(scale, view.height * 0.4 / max(height, 1))
        scale = min(max(scale, fitScreen * 1.1), fitScreen * 4, pdfView.maxScaleFactor)
        // Never hand PDFKit a broken number (NaN zoom renders garbage and eats memory).
        guard scale.isFinite, scale > 0, pr.isFiniteRect else {
            goTo(page: index, rect: nil)
            return
        }
        pdfView.autoScales = false // or PDFKit fits the width again on the next layout
        pdfView.scaleFactor = scale
        pdfView.layoutIfNeeded()
        pdfView.go(to: pr, on: page)
        pdfView.layoutIfNeeded()
        center(pr, on: page, animated: true)
    }

    /// Fits the page you're on to the screen's width, edge to edge (no background
    /// showing beside it), from the top of the page.
    func fitPage() {
        guard let page = pdfView.currentPage else { return }
        let size = Self.displayedSize(page)
        let width = pdfView.bounds.inset(by: pdfView.safeAreaInsets).width
        guard size.width > 1, size.height > 1, width > 10 else { return }
        let scale = width / size.width
        guard scale.isFinite, scale > 0 else { return }
        pdfView.autoScales = false
        pdfView.minScaleFactor = min(pdfView.minScaleFactor, scale)
        pdfView.scaleFactor = min(scale, pdfView.maxScaleFactor)
        pdfView.layoutIfNeeded()
        pdfView.go(to: page)
    }

    /// The page is (about) as wide as a page area of this width: fitted, not zoomed.
    private func fillsWidth(_ width: CGFloat) -> Bool {
        guard width > 10, let page = pdfView.currentPage else { return false }
        if pdfView.autoScales { return true }
        let shown = Self.displayedSize(page).width * pdfView.scaleFactor
        return shown.isFinite && abs(shown - width) < width * 0.04
    }

    /// Fits the page to the width in one step, staying at the same place in the book.
    private func fitWidth(keeping place: CGFloat?) {
        guard let page = pdfView.currentPage else { return }
        let size = Self.displayedSize(page)
        let width = pdfView.bounds.inset(by: pdfView.safeAreaInsets).width
        guard size.width > 1, width > 10 else { return }
        let scale = width / size.width
        guard scale.isFinite, scale > 0 else { return }
        pdfView.autoScales = false
        pdfView.minScaleFactor = min(pdfView.minScaleFactor, scale)
        pdfView.scaleFactor = min(scale, pdfView.maxScaleFactor)
        pdfView.layoutIfNeeded()
        guard let place, let sv = scrollView, sv.contentSize.height > 1 else { return }
        let inset = sv.adjustedContentInset
        let maxY = max(-inset.top, sv.contentSize.height - sv.bounds.height + inset.bottom)
        let y = min(max(place * sv.contentSize.height - inset.top, -inset.top), maxY)
        if y.isFinite { sv.contentOffset.y = y }
    }

    /// Scrolls so a rect (page coordinates) sits in the middle of the screen.
    private func center(_ pageRect: CGRect, on page: PDFPage, animated: Bool) {
        guard let sv = scrollView, pageRect.isFiniteRect else { return }
        let r = pdfView.convert(pdfView.convert(pageRect, from: page), to: sv)
        guard r.isFiniteRect, sv.contentSize.width.isFinite, sv.contentSize.height.isFinite else { return }
        let inset = sv.adjustedContentInset
        let visible = sv.bounds.inset(by: inset)
        var offset = CGPoint(x: r.midX - inset.left - max(visible.width - coveredRight, 100) / 2,
                             y: r.midY - inset.top - max(visible.height - coveredBottom, 100) / 2)
        let maxX = max(-inset.left, sv.contentSize.width - sv.bounds.width + inset.right)
        let maxY = max(-inset.top, sv.contentSize.height - sv.bounds.height + inset.bottom)
        offset.x = min(max(offset.x, -inset.left), maxX)
        offset.y = min(max(offset.y, -inset.top), maxY)
        guard offset.x.isFinite, offset.y.isFinite else { return }
        sv.setContentOffset(offset, animated: animated)
    }

    /// Width on the right covered by the tool rail and an open side panel.
    var coveredRight: CGFloat = 64
    /// Height at the bottom covered by the list card (portrait).
    var coveredBottom: CGFloat = 0

    /// The part of the PDF view you can see past the bars, the rail and a panel.
    private var visibleArea: CGRect {
        var r = pdfView.bounds.inset(by: pdfView.safeAreaInsets)
        r.size.width = max(r.width - coveredRight, 0)
        r.size.height = max(r.height - coveredBottom, 0)
        return r
    }

    /// If the zoom or scroll position ever became an invalid number (NaN / infinite —
    /// PDFKit then draws garbage and runs out of memory), go back to fitting the width.
    private func repairBrokenZoom() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let scale = pdfView.scaleFactor
        if !scale.isFinite || scale <= 0 {
            pdfView.autoScales = true
        }
        if let sv = scrollView, !(sv.contentOffset.x.isFinite && sv.contentOffset.y.isFinite) {
            sv.contentOffset = .zero
            if let page = pdfView.currentPage ?? session?.pdf.page(at: 0) { pdfView.go(to: page) }
        }
    }

    /// A picture of the page that glides while the page area changes size.
    func glideCover() -> GlideCover? {
        GlideCover(over: self, background: pdfView.backgroundColor ?? .systemGroupedBackground)
    }

    /// PDFKit's scroll view, inside the PDF view.
    private var scrollView: UIScrollView? {
        func find(_ v: UIView) -> UIScrollView? {
            if let s = v as? UIScrollView { return s }
            for sub in v.subviews { if let s = find(sub) { return s } }
            return nil
        }
        return find(pdfView)
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

    /// Shows the ✓ next to a circled word waiting for its definition (nil hides it).
    func showConfirm(_ term: Highlight?) {
        if let term, let first = term.rects.first {
            let rect = term.rects.dropFirst().reduce(first) { $0.union($1) }
            confirm = (term.page, rect)
        } else {
            confirm = nil
        }
        for (index, overlay) in overlays { overlay.setConfirm(confirm?.page == index ? confirm?.rect : nil) }
    }

    /// Highlights changed: redraw them on the pages on screen (the others draw theirs
    /// when they appear).
    func syncHighlights() {
        for (index, overlay) in overlays { overlay.setHighlights(highlightItems(onPage: index)) }
    }

    private func highlightItems(onPage index: Int) -> [(rect: CGRect, color: UIColor, style: HighlightStyle)] {
        guard let s = session else { return [] }
        return s.highlights(onPage: index).flatMap { h in
            s.displayRects(h).map { (rect: $0, color: h.uiColor, style: h.style) }
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
        overlay.onConfirm = { [weak s] in s?.confirmDefinition() }
        overlay.setConfirm(confirm?.page == index ? confirm?.rect : nil)
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
        overlay.inkActive = scribbling
        let tool: PKTool
        if s.tool == .erase {
            tool = PKEraserTool(s.scribble.eraser.pk)
        } else if s.scribble.lasso {
            tool = PKLassoTool()
        } else {
            tool = s.scribble.inkTool
        }
        let shape = s.tool == .pen && !s.scribble.lasso ? s.scribble.shape : nil
        overlay.ink?.setActive(scribbling, tool: tool, ruler: s.scribble.ruler, shape: shape,
                               erasing: s.tool == .erase)
    }

    func saveAllInk() {
        for overlay in overlays.values { overlay.ink?.saveNow() }
    }

    /// The page you're on (the most visible one).
    private var visiblePageIndex: Int? {
        guard let s = session, let page = pdfView.currentPage else { return nil }
        return s.pdf.index(for: page)
    }

    /// Tidies the handwriting on every page on screen (not just PDFKit's "current"
    /// page, which can be the other one of two you're looking at).
    func tidyCurrentPage() {
        let onScreen = overlays.values.filter {
            $0.window != nil && $0.convert($0.bounds, to: pdfView).intersects(pdfView.bounds)
        }
        let visible = onScreen.compactMap(\.ink).filter(\.hasStrokes)
        guard !visible.isEmpty else {
            session?.showToast("No handwriting on this page")
            return
        }
        var remaining = visible.count
        var tidied = 0, busy = false
        for ink in visible {
            ink.tidy(all: true) { [weak self] outcome in
                switch outcome {
                case .tidied(let n): tidied += n
                case .busy: busy = true
                case .nothing, .unreadable: break
                }
                remaining -= 1
                guard remaining == 0 else { return }
                if tidied > 0 {
                    self?.session?.showToast("Tidied \(tidied) bit\(tidied == 1 ? "" : "s") of handwriting")
                } else if busy {
                    self?.session?.showToast("Still writing — tap Tidy again in a moment")
                } else {
                    self?.session?.showToast("Couldn't read the handwriting — try writing a little larger")
                }
            }
        }
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
        // Give the jump a moment to zoom and scroll the page into place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.applyPendingFlash() }
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
    /// * right after circling a word, a line drawn just under words underlines them as
    ///   its definition;
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
        case .highlight(let r): s.addHighlight(on: lp, range: trimmed(r, lp, points)); return
        // A line under words only means something right after circling a word: it's
        // that word's definition. Otherwise it's an ordinary highlight stroke.
        case .underline(let r) where s.pendingTerm != nil:
            s.addHighlight(on: lp, range: r, underline: true)
            return
        case .underline, .none: break
        }
        if let sel = PageHitTester.selection(for: points, in: pages) {
            s.addHighlight(on: sel.page, range: trimmed(sel.range, sel.page, points))
        }
    }

    /// Precise ends: a word at either end that the stroke only grazes (under ~30% of its
    /// width) isn't part of the highlight — so starting just past a highlighted word
    /// doesn't drag it in (and extend that highlight) when you meant the next word.
    private static func trimmed(_ r: ClosedRange<Int>, _ lp: LogicalPage, _ points: [CGPoint]) -> ClosedRange<Int> {
        guard r.upperBound < lp.tokens.count, let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return r }
        // A down-the-margin stroke takes whole lines: nothing to trim.
        if maxY - minY > (maxX - minX) * 1.5 { return r }
        func covered(_ i: Int) -> CGFloat {
            let t = lp.tokens[i].rect
            guard t.width > 0 else { return 1 }
            let band = t.insetBy(dx: 0, dy: -t.height * 0.6)
            let xs = points.filter { $0.y >= band.minY && $0.y <= band.maxY }.map(\.x)
            guard let a = xs.min(), let b = xs.max() else { return 1 } // not on that line: leave it
            return max(0, min(b, t.maxX) - max(a, t.minX)) / t.width
        }
        var lo = r.lowerBound, hi = r.upperBound
        while lo < hi, covered(lo) < 0.3 { lo += 1 }
        while hi > lo, covered(hi) < 0.3 { hi -= 1 }
        return lo...hi
    }

    private func cancelStroke() {
        inkLayer.path = nil
        clearPreview()
        stroke = nil
    }

    // MARK: - Read aloud

    @objc private func handleReadTap(_ g: UITapGestureRecognizer) {
        guard let s = session, s.speech.isActive else { return }
        readAloud(from: g.location(in: pdfView))
    }

    @objc private func handleReadDoubleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        readAloud(from: g.location(in: pdfView))
    }

    /// Reads aloud from the word at a point in the PDF view.
    private func readAloud(from p: CGPoint) {
        guard let s = session else { return }
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
