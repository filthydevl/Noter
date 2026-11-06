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
/// * Read-aloud position is drawn as a separate box annotation that the pencil never
///   interacts with.
final class PDFReaderController: UIView, UIGestureRecognizerDelegate {
    let pdfView = PDFView()
    private let inkOverlay = UIView()
    private let inkLayer = CAShapeLayer()
    private let inkPath = UIBezierPath()
    private let pencil = PencilStrokeRecognizer(target: nil, action: nil)
    private lazy var readTap = UITapGestureRecognizer(target: self, action: #selector(handleReadTap(_:)))
    private weak var session: DocumentSession?

    private var rendered: [UUID: (highlight: Highlight, annotations: [PDFAnnotation])] = [:]
    private var previewAnnotations: [PDFAnnotation] = []
    private var speechAnnotation: PDFAnnotation?
    private var speechLine: SpeechLine?
    private var hookedScrollViews = Set<ObjectIdentifier>()
    private var didInitialScroll = false
    private var ready = false

    private struct SpeechLine: Equatable {
        let slot: SlotKey
        let line: Int
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
        backgroundColor = .secondarySystemBackground

        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        pdfView.backgroundColor = .secondarySystemBackground
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
        let padded = rect.insetBy(dx: -0.003, dy: -rect.height * 0.12)
        let a = PDFAnnotation(bounds: geometry.pageRect(fromNormalized: padded), forType: .highlight, withProperties: nil)
        a.color = color
        return a
    }

    private func showPreview(_ lp: LogicalPage, _ r: ClosedRange<Int>, on page: PDFPage,
                             geometry: PageGeometry, color: HighlightColor) {
        clearPreview()
        for rect in lp.lineRects(for: r) {
            let a = Self.highlightAnnotation(rect: rect, geometry: geometry, color: color.uiColor.withAlphaComponent(0.35))
            page.addAnnotation(a)
            previewAnnotations.append(a)
        }
    }

    private func clearPreview() {
        previewAnnotations.forEach { $0.page?.removeAnnotation($0) }
        previewAnnotations.removeAll()
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
                showPreview(pages[h], r, on: st.page, geometry: st.geometry, color: s.color)
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

    func showSpeech(_ position: SpeechPosition?) {
        guard let s = session, let position, let lp = s.logicalPage(position.slot),
              let li = lp.lineIndex(forToken: position.token), let page = s.pdf.page(at: position.pdfIndex) else {
            if let a = speechAnnotation { a.page?.removeAnnotation(a) }
            speechAnnotation = nil
            speechLine = nil
            return
        }
        let key = SpeechLine(slot: position.slot, line: li)
        guard key != speechLine else { return }
        speechLine = key
        if let a = speechAnnotation { a.page?.removeAnnotation(a) }

        let r = lp.lines[li].rect
        let pr = PageGeometry(page: page).pageRect(fromNormalized: r.insetBy(dx: -0.008, dy: -r.height * 0.3))
        let a = PDFAnnotation(bounds: pr, forType: .square, withProperties: nil)
        a.color = UIColor.systemBlue.withAlphaComponent(0.85)
        a.interiorColor = UIColor.systemBlue.withAlphaComponent(0.08)
        let border = PDFBorder()
        border.lineWidth = 1.5
        a.border = border
        page.addAnnotation(a)
        speechAnnotation = a
        follow(pr, on: page)
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
