import UIKit
import SwiftUI

/// The OCR transcript, one cell per book page, loaded lazily so a 1,000-page book
/// scrolls as smoothly as a 10-page one. Pencil highlighting works exactly like on
/// the PDF and both views share the same highlights.
final class TranscriptController: UIView, UICollectionViewDataSource, UICollectionViewDelegate,
    UIGestureRecognizerDelegate {
    private weak var session: DocumentSession?
    private var collectionView: UICollectionView!
    private let pencil = PencilStrokeRecognizer(target: nil, action: nil)
    private lazy var readTap = UITapGestureRecognizer(target: self, action: #selector(handleReadTap(_:)))
    /// Double-tap a word: read aloud from there.
    private lazy var readDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleReadDoubleTap(_:)))
    private let inkLayer = CAShapeLayer()
    private let inkPath = UIBezierPath()
    private var didInitialScroll = false
    private var initialScrollScheduled = false
    private var speechIndexPath: IndexPath?
    /// The circled word waiting for its definition (its ✓ is shown next to it).
    private var confirmTerm: Highlight?
    /// Widest the column of text may get (reading options).
    private var maxTextWidth: CGFloat = 740

    private struct Stroke {
        let indexPath: IndexPath
        let page: LogicalPage
        var processed = 0
        var hits: [StrokeHit] = []
        var range: ClosedRange<Int>?
        var erased = false
        var length: CGFloat = 0
        var last: CGPoint?
        /// The stroke in the cell's text view coordinates (for circles / underlines).
        var points: [CGPoint] = []
    }
    private var stroke: Stroke?

    init(session: DocumentSession) {
        self.session = session
        super.init(frame: .zero)

        listLayout = UICollectionViewCompositionalLayout { [weak self] _, env in
            let width = env.container.effectiveContentSize.width
            let maxText = self?.maxTextWidth ?? 740
            let side = max(28, (width - maxText) / 2)
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(1200))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: side, bottom: 0, trailing: side)
            return section
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: listLayout)
        collectionView.backgroundColor = session.textAppearance.theme.background
        maxTextWidth = session.textAppearance.width.points
        overrideUserInterfaceStyle = session.textAppearance.theme.interfaceStyle
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.contentInset = UIEdgeInsets(top: 48, left: 0, bottom: 120, right: 0)
        collectionView.register(TranscriptCell.self, forCellWithReuseIdentifier: TranscriptCell.reuseID)
        collectionView.panGestureRecognizer.allowedTouchTypes = fingerTouchTypes
        collectionView.pinchGestureRecognizer?.allowedTouchTypes = fingerTouchTypes
        addSubview(collectionView)

        inkLayer.fillColor = nil
        inkLayer.lineCap = .round
        inkLayer.lineJoin = .round
        inkLayer.zPosition = 100
        collectionView.layer.addSublayer(inkLayer)

        pencil.addTarget(self, action: #selector(handlePencil(_:)))
        collectionView.addGestureRecognizer(pencil)
        readTap.allowedTouchTypes = fingerTouchTypes
        readTap.delegate = self
        collectionView.addGestureRecognizer(readTap)
        readDoubleTap.numberOfTapsRequired = 2
        readDoubleTap.allowedTouchTypes = fingerTouchTypes
        readDoubleTap.delegate = self
        collectionView.addGestureRecognizer(readDoubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// One page after another (portrait, or two pages off).
    private var listLayout: UICollectionViewLayout!
    /// Two pages side by side (landscape with "Two pages" on).
    private let bookLayout = TwoPageLayout()
    private var showingTwoPages = false

    /// Two pages fit: landscape and wide enough for two columns of text.
    private var wantsTwoPages: Bool {
        guard let s = session, s.textAppearance.twoPages else { return false }
        return bounds.width > bounds.height && bounds.width >= 900
    }

    /// Switches between one and two pages across when the option or the shape changes,
    /// keeping your place.
    private func updatePageLayout() {
        let want = wantsTwoPages
        guard want != showingTwoPages, bounds.width > 0 else { return }
        showingTwoPages = want
        let page = session?.currentPage ?? 0
        bookLayout.maxTextWidth = maxTextWidth
        bookLayout.resetHeights()
        collectionView.setCollectionViewLayout(want ? bookLayout : listLayout, animated: false)
        collectionView.reloadData()
        DispatchQueue.main.async { [weak self] in self?.scroll(toPage: page) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionView.frame = bounds
        updatePageLayout()
        if !didInitialScroll, !initialScrollScheduled, bounds.height > 0, let s = session {
            initialScrollScheduled = true
            DispatchQueue.main.async { [weak self] in self?.scroll(toPage: s.currentPage) }
        }
    }

    // MARK: - Data

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        session?.pageCount ?? 0
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        session?.halfCount(section) ?? 1
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TranscriptCell.reuseID, for: indexPath) as! TranscriptCell
        guard let s = session else { return cell }
        if let pages = s.logicalPages(indexPath.section), indexPath.item < pages.count {
            let lp = pages[indexPath.item]
            cell.configure(page: lp, header: s.headerLabel(for: lp.slot),
                           highlights: s.transcriptHighlightRanges(lp), skipped: s.skippedRanges(lp),
                           marks: s.questionTextRanges(lp), fontSize: s.transcriptFontSize,
                           appearance: s.textAppearance)
            if let p = s.speechPosition, p.slot == lp.slot { cell.setSpeech(token: p.token) }
            cell.onConfirm = { [weak s] in s?.confirmDefinition() }
            cell.setConfirm(confirmRange(in: lp))
        } else {
            cell.configurePlaceholder(header: "PDF page \(indexPath.section + 1)", fontSize: s.transcriptFontSize,
                                      appearance: s.textAppearance)
            if s.viewMode == .transcript { s.ocr.setFocus(indexPath.section) }
        }
        return cell
    }

    func reloadAll() {
        collectionView.reloadData()
        if let s = session { DispatchQueue.main.async { [weak self] in self?.scroll(toPage: s.currentPage) } }
    }

    /// OCR finished a page: swap the placeholder for text without making the list jump.
    func pageBecameReady(_ index: Int) {
        guard index < collectionView.numberOfSections else { return }
        let anchor = collectionView.indexPathsForVisibleItems.min()
        var anchorOffset: CGFloat = 0
        if let a = anchor, let attrs = collectionView.layoutAttributesForItem(at: a) {
            anchorOffset = attrs.frame.minY - collectionView.contentOffset.y
        }
        UIView.performWithoutAnimation {
            collectionView.reloadSections(IndexSet(integer: index))
        }
        if let a = anchor, index < a.section, !collectionView.isDragging, !collectionView.isDecelerating {
            collectionView.layoutIfNeeded()
            if let attrs = collectionView.layoutAttributesForItem(at: a) {
                collectionView.contentOffset.y = attrs.frame.minY - anchorOffset
            }
        }
    }

    /// Shows the ✓ next to a circled word waiting for its definition (nil hides it).
    func showConfirm(_ term: Highlight?) {
        confirmTerm = term
        for cell in collectionView.visibleCells {
            guard let cell = cell as? TranscriptCell, let lp = cell.page else { continue }
            cell.setConfirm(confirmRange(in: lp))
        }
    }

    private func confirmRange(in lp: LogicalPage) -> NSRange? {
        guard let t = confirmTerm, t.page == lp.pdfIndex, let r = lp.range(of: t) else { return nil }
        return lp.textRange(for: r)
    }

    func refreshHighlights() {
        guard let s = session else { return }
        for cell in collectionView.visibleCells {
            guard let cell = cell as? TranscriptCell, let lp = cell.page else { continue }
            cell.applyHighlights(s.transcriptHighlightRanges(lp))
        }
    }

    /// Reading options changed: page color, column width, then re-lay out the text.
    func appearanceChanged() {
        guard let s = session else { return }
        let a = s.textAppearance
        overrideUserInterfaceStyle = a.theme.interfaceStyle
        collectionView.backgroundColor = a.theme.background
        maxTextWidth = a.width.points
        bookLayout.maxTextWidth = maxTextWidth
        bookLayout.resetHeights()
        collectionView.collectionViewLayout.invalidateLayout()
        if wantsTwoPages != showingTwoPages {
            updatePageLayout()
        } else {
            reloadAll()
        }
    }

    /// Questions were found / toggled: redraw the marks on the visible pages.
    func refreshMarks() {
        guard let s = session else { return }
        for cell in collectionView.visibleCells {
            guard let cell = cell as? TranscriptCell, let lp = cell.page else { continue }
            cell.applyMarks(s.questionTextRanges(lp))
        }
    }

    /// After a jump: brings the range on screen and blinks a box around it.
    func flash(slot: SlotKey, range: NSRange) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let ip = IndexPath(item: slot.half, section: slot.pdfIndex)
            guard let cell = self.collectionView.cellForItem(at: ip) as? TranscriptCell else { return }
            cell.layoutIfNeeded()
            if let r = cell.rect(for: range) {
                let target = cell.textView.convert(r, to: self.collectionView)
                let inset = self.collectionView.adjustedContentInset
                let visibleHeight = self.collectionView.bounds.height - inset.top - inset.bottom
                let y = target.midY - inset.top - visibleHeight * 0.4
                let maxY = max(-inset.top, self.collectionView.contentSize.height - self.collectionView.bounds.height
                    + inset.bottom)
                self.collectionView.setContentOffset(CGPoint(x: 0, y: min(max(y, -inset.top), maxY)), animated: false)
            }
            cell.flash(range: range)
        }
    }

    /// Skip options changed: re-dim skipped text in the visible pages.
    func refreshSkipped() {
        collectionView.reconfigureItems(at: collectionView.indexPathsForVisibleItems)
    }

    func refreshHeaders() {
        guard let s = session else { return }
        for cell in collectionView.visibleCells {
            guard let cell = cell as? TranscriptCell, let lp = cell.page else { continue }
            cell.header.text = s.headerLabel(for: lp.slot)
        }
    }

    // MARK: - Position

    func scroll(toPage page: Int, half: Int = 0) {
        guard page >= 0, page < collectionView.numberOfSections else { return }
        let items = collectionView.numberOfItems(inSection: page)
        guard items > 0 else { return }
        let ip = IndexPath(item: min(max(half, 0), items - 1), section: page)
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: ip, at: .top, animated: false)
        didInitialScroll = true
        // Cells size themselves as they appear; settle once more.
        DispatchQueue.main.async { [weak self] in
            guard let self, ip.section < self.collectionView.numberOfSections,
                  ip.item < self.collectionView.numberOfItems(inSection: ip.section) else { return }
            self.collectionView.scrollToItem(at: ip, at: .top, animated: false)
        }
    }

    /// The word at the top of the screen.
    func topAnchor() -> TextAnchor? {
        let inset = collectionView.adjustedContentInset
        let y = collectionView.contentOffset.y + inset.top + 12
        let probe = CGPoint(x: collectionView.bounds.midX, y: y)
        guard let ip = collectionView.indexPathForItem(at: probe) ?? collectionView.indexPathsForVisibleItems.min()
        else { return nil }
        let slot = SlotKey(pdfIndex: ip.section, half: ip.item)
        guard let cell = collectionView.cellForItem(at: ip) as? TranscriptCell, cell.page != nil else {
            return TextAnchor(slot: slot, token: 0)
        }
        let local = cell.textView.convert(CGPoint(x: 0, y: y), from: collectionView)
        return TextAnchor(slot: slot, token: cell.token(atLineY: local.y) ?? 0)
    }

    /// Scrolls so the line with this word is near the top of the screen.
    func scroll(to anchor: TextAnchor) {
        scroll(toPage: anchor.slot.pdfIndex, half: anchor.slot.half)
        guard anchor.token > 0 else { return }
        // Cells size themselves as they appear: place the line once they've settled.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { self?.placeLine(anchor) }
        }
    }

    private func placeLine(_ anchor: TextAnchor) {
        let ip = IndexPath(item: anchor.slot.half, section: anchor.slot.pdfIndex)
        guard let s = session, let lp = s.logicalPage(anchor.slot), anchor.token < lp.tokens.count,
              let cell = collectionView.cellForItem(at: ip) as? TranscriptCell else { return }
        cell.layoutIfNeeded()
        guard let r = cell.rect(for: lp.textRange(for: anchor.token...anchor.token)) else { return }
        let target = cell.textView.convert(r, to: collectionView)
        let inset = collectionView.adjustedContentInset
        let maxY = max(-inset.top, collectionView.contentSize.height - collectionView.bounds.height + inset.bottom)
        let y = target.minY - inset.top - 24
        collectionView.setContentOffset(CGPoint(x: 0, y: min(max(y, -inset.top), maxY)), animated: false)
    }

    func topVisibleSlot() -> SlotKey? {
        let probe = CGPoint(x: collectionView.bounds.midX,
                            y: collectionView.contentOffset.y + collectionView.adjustedContentInset.top + 40)
        guard let ip = collectionView.indexPathForItem(at: probe) ?? collectionView.indexPathsForVisibleItems.min()
        else { return nil }
        return SlotKey(pdfIndex: ip.section, half: ip.item)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard didInitialScroll, let s = session, s.viewMode == .transcript, let slot = topVisibleSlot() else { return }
        s.setCurrentPage(slot.pdfIndex)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        session?.noteUserActivity()
    }

    // MARK: - Pencil

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
        guard let s = session, let p = g.points.first,
              let ip = collectionView.indexPathForItem(at: p),
              let cell = collectionView.cellForItem(at: ip) as? TranscriptCell,
              let lp = cell.page else { return }
        guard s.penMode == .highlight else {
            s.showToast("Scribble draws on the PDF view")
            return
        }
        s.noteUserActivity()
        stroke = Stroke(indexPath: ip, page: lp)
        inkPath.removeAllPoints()
        inkPath.move(to: p)
        let erasing = s.tool == .erase
        inkLayer.strokeColor = (erasing ? UIColor.systemGray : s.color.uiColor).withAlphaComponent(0.4).cgColor
        inkLayer.lineWidth = erasing ? 16 : 3
    }

    private func consume(_ g: PencilStrokeRecognizer) {
        guard var st = stroke, let s = session,
              let cell = collectionView.cellForItem(at: st.indexPath) as? TranscriptCell else { return }
        let pts = g.points
        guard st.processed < pts.count else { return }
        var touched: [Int] = []
        for p in pts[st.processed...] {
            if let last = st.last { st.length += hypot(p.x - last.x, p.y - last.y) }
            st.last = p
            inkPath.addLine(to: p)
            st.points.append(cell.textView.convert(p, from: collectionView))
            if let hit = cell.hit(at: cell.textView.convert(p, from: collectionView)) {
                st.hits.append(hit)
                touched.append(hit.token)
            }
        }
        st.processed = pts.count
        inkLayer.path = inkPath.cgPath

        if s.tool == .pen {
            if st.length > 6, let r = Snapper.range(for: st.hits, referenceWidth: cell.textWidth), r != st.range {
                st.range = r
                cell.showPreview(st.page.textRange(for: r), color: s.color.uiColor)
            }
        } else if !touched.isEmpty {
            let ids = Set(s.highlights(onPage: st.page.pdfIndex).filter { h in
                guard let r = st.page.range(of: h) else { return false }
                return touched.contains { r.contains($0) }
            }.map(\.id))
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
        let cell = collectionView.cellForItem(at: st.indexPath) as? TranscriptCell
        defer { cell?.showPreview(nil, color: nil) }
        guard s.tool == .pen, st.length > 6 else { return }
        // A circle around a word / phrase, a loop around a paragraph, or an underline.
        // (A line under words only counts right after circling a word: its definition.)
        if let cell, let shape = Self.shapeAction(st.points, cell) {
            switch shape {
            case .term(let r):
                s.addTerm(on: st.page, range: r)
                return
            case .highlight(let r):
                s.addHighlight(on: st.page, range: r)
                return
            case .underline(let r) where s.pendingTerm != nil:
                s.addHighlight(on: st.page, range: r, underline: true)
                return
            case .underline, .none:
                break
            }
        }
        if let r = st.range ?? Snapper.range(for: st.hits, referenceWidth: cell?.textWidth ?? 600) {
            s.addHighlight(on: st.page, range: r)
        }
    }

    /// What a highlighter stroke's shape means here, if it's a circle or an underline.
    private static func shapeAction(_ points: [CGPoint], _ cell: TranscriptCell) -> StrokeShapeDetector.Action? {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let area = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -40, dy: -60)
        let action = StrokeShapeDetector.action(points, tokens: cell.tokenRects(in: area))
        if case .none = action { return nil }
        return action
    }

    private func cancelStroke() {
        inkLayer.path = nil
        if let st = stroke, let cell = collectionView.cellForItem(at: st.indexPath) as? TranscriptCell {
            cell.showPreview(nil, color: nil)
        }
        stroke = nil
    }

    // MARK: - Read aloud

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        g === readTap ? (session?.speech.isActive ?? false) : true
    }

    /// While reading aloud, tapping a word with a finger jumps the voice there.
    @objc private func handleReadTap(_ g: UITapGestureRecognizer) {
        guard let s = session, s.speech.isActive else { return }
        readAloud(from: g.location(in: collectionView))
    }

    @objc private func handleReadDoubleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        readAloud(from: g.location(in: collectionView))
    }

    /// Reads aloud from the word at a point in the list.
    private func readAloud(from p: CGPoint) {
        guard let s = session else { return }
        guard let ip = collectionView.indexPathForItem(at: p),
              let cell = collectionView.cellForItem(at: ip) as? TranscriptCell, let lp = cell.page,
              let hit = cell.hit(at: cell.textView.convert(p, from: collectionView)) else { return }
        s.speech.play(from: lp.slot, token: hit.token)
    }

    func showSpeech(_ position: SpeechPosition?) {
        let ip = position.map { IndexPath(item: $0.half, section: $0.pdfIndex) }
        if let old = speechIndexPath, old != ip, let cell = collectionView.cellForItem(at: old) as? TranscriptCell {
            cell.setSpeech(token: nil)
        }
        speechIndexPath = ip
        guard let position, let ip, ip.section < collectionView.numberOfSections,
              ip.item < collectionView.numberOfItems(inSection: ip.section) else { return }
        if let cell = collectionView.cellForItem(at: ip) as? TranscriptCell {
            if let line = cell.setSpeech(token: position.token) {
                follow(cell.textView.convert(line, to: collectionView))
            }
        } else if canFollow {
            collectionView.scrollToItem(at: ip, at: .top, animated: true)
        }
    }

    private var canFollow: Bool {
        guard let s = session else { return false }
        return s.viewMode == .transcript && stroke == nil && s.secondsSinceUserActivity > 4
    }

    /// Keeps the line being read in the upper third of the screen.
    private func follow(_ rect: CGRect) {
        guard canFollow else { return }
        let inset = collectionView.adjustedContentInset
        let visible = CGRect(x: 0, y: collectionView.contentOffset.y + inset.top,
                             width: collectionView.bounds.width,
                             height: collectionView.bounds.height - inset.top - inset.bottom)
        guard !visible.insetBy(dx: 0, dy: visible.height * 0.15).contains(rect) else { return }
        let target = rect.minY - visible.height * 0.3 - inset.top
        let maxY = max(-inset.top, collectionView.contentSize.height - collectionView.bounds.height + inset.bottom)
        collectionView.setContentOffset(CGPoint(x: 0, y: min(max(target, -inset.top), maxY)), animated: true)
    }
}

struct TranscriptRepresentable: UIViewRepresentable {
    let session: DocumentSession

    func makeUIView(context: Context) -> TranscriptController {
        let view = TranscriptController(session: session)
        session.transcriptController = view
        return view
    }

    func updateUIView(_ uiView: TranscriptController, context: Context) {}
}
