import UIKit
import PencilKit

/// A PencilKit canvas whose undo steps go to one shared undo manager, so the toolbar's
/// undo / redo work across pages.
final class InkCanvas: PKCanvasView {
    weak var sharedUndo: UndoManager?
    override var undoManager: UndoManager? { sharedUndo ?? super.undoManager }
}

/// The scribble layer of one PDF page: a PencilKit canvas (pencil draws, fingers still
/// scroll and tap through) plus tidied text. Lives inside the page's overlay, so it moves
/// and zooms with the page. The drawing is stored in page points, so it lines up at any
/// zoom.
@MainActor
final class PageInkView: UIView, PKCanvasViewDelegate {
    let pageIndex: Int
    private let docID: UUID
    /// The displayed page's size in points.
    private let pageSize: CGSize
    private let canvas = InkCanvas()
    private let shapeView = ShapeOverlayView()
    private let undo: UndoManager
    private var texts: [InkText] = []
    private var labels: [UUID: InkTextLabel] = [:]
    /// Drawing (page points) waiting for the view to get a size.
    private var pending: PKDrawing?
    private var appliedSize: CGSize = .zero
    private var programmatic = false
    /// Strokes before this index were already considered for auto-tidy.
    private var considered = 0
    private var tidyWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?

    weak var settings: ScribbleSettings?
    var onActivity: (() -> Void)?
    var onMessage: ((String) -> Void)?

    init(docID: UUID, pageIndex: Int, pageSize: CGSize, undo: UndoManager) {
        self.docID = docID
        self.pageIndex = pageIndex
        self.pageSize = pageSize
        self.undo = undo
        super.init(frame: .zero)
        backgroundColor = .clear
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.sharedUndo = undo
        canvas.delegate = self
        canvas.isUserInteractionEnabled = false
        addSubview(canvas)

        shapeView.pageSize = pageSize
        shapeView.style = { [weak self] in
            guard let settings = self?.settings else { return (colorHex: "#1A1A1AFF", width: 3) }
            return (colorHex: settings.color.uiColor.withAlphaComponent(settings.opacity).hexString,
                    width: max(settings.width * 0.7, 1.5))
        }
        shapeView.onCommit = { [weak self] before, after in self?.shapesChanged(after, undoFrom: before) }
        addSubview(shapeView)

        let ink = InkStore.load(docID, page: pageIndex)
        pending = ink.drawing.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
        texts = ink.texts
        shapeView.setShapes(ink.shapes ?? [])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    /// Page points → this view.
    private var toView: CGAffineTransform {
        CGAffineTransform(scaleX: bounds.width / max(pageSize.width, 1), y: bounds.height / max(pageSize.height, 1))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        shapeView.frame = bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        if let drawing = pending {
            setDrawing(drawing.transformed(using: toView))
            pending = nil
            considered = canvas.drawing.strokes.count
        } else if appliedSize != .zero, appliedSize != bounds.size {
            // The overlay was resized (zoom): keep the drawing on the same words.
            let s = CGAffineTransform(scaleX: bounds.width / appliedSize.width, y: bounds.height / appliedSize.height)
            setDrawing(canvas.drawing.transformed(using: s))
        }
        appliedSize = bounds.size
        layoutLabels()
    }

    private func setDrawing(_ drawing: PKDrawing) {
        programmatic = true
        canvas.drawing = drawing
        programmatic = false
    }

    /// The drawing in page points.
    private var pageDrawing: PKDrawing {
        canvas.drawing.transformed(using: toView.inverted())
    }

    // MARK: Tools

    /// `shape`: drawing shapes instead of ink. `erasing`: the eraser also erases shapes.
    func setActive(_ active: Bool, tool: PKTool, ruler: Bool, shape: ShapeKind?, erasing: Bool) {
        canvas.isUserInteractionEnabled = active && shape == nil
        canvas.tool = tool
        canvas.isRulerActive = active && ruler && shape == nil
        if !active {
            shapeView.mode = .off
        } else if let shape {
            shapeView.mode = .draw(shape)
        } else {
            shapeView.mode = erasing ? .erase : .off
        }
        for l in labels.values { l.isUserInteractionEnabled = active }
    }

    /// A shape was drawn, moved, reshaped or deleted.
    private func shapesChanged(_ new: [InkShape], undoFrom old: [InkShape]) {
        undo.registerUndo(withTarget: self) { view in
            MainActor.assumeIsolated {
                view.shapeView.setShapes(old)
                view.shapesChanged(old, undoFrom: new)
            }
        }
        undo.setActionName("Shape")
        onActivity?()
        saveNow()
    }

    // MARK: Drawing changes

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !programmatic else { return }
        onActivity?()
        scheduleSave()
        let count = canvas.drawing.strokes.count
        if count < considered { considered = count }
        if settings?.autoTidy == true, count > considered {
            // Wait until you've paused writing.
            tidyWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.tidy(all: false) }
            tidyWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        guard pending == nil else { return } // never loaded into the canvas: nothing changed
        let drawing = pageDrawing
        let shapes = shapeView.shapes
        InkStore.save(PageInk(drawing: drawing.strokes.isEmpty ? nil : drawing.dataRepresentation(), texts: texts,
                              shapes: shapes.isEmpty ? nil : shapes),
                      docID, page: pageIndex)
    }

    // MARK: Tidy handwriting

    enum TidyOutcome {
        case nothing, unreadable, busy
        case tidied(Int)
    }

    /// Whether there's handwriting (ink strokes) on this page.
    var hasStrokes: Bool { pending == nil && !canvas.drawing.strokes.isEmpty }

    /// Turns handwriting into neat lettering: everything on the page (`all`, when you
    /// tap Tidy), or just what you wrote since the last tidy (auto-tidy, stricter so
    /// drawings aren't mistaken for words).
    func tidy(all: Bool, done: ((TidyOutcome) -> Void)? = nil) {
        tidyWork?.cancel()
        guard pending == nil else { done?(.nothing); return }
        let strokes = pageDrawing.strokes
        let start = all ? 0 : min(considered, strokes.count)
        considered = strokes.count
        guard start < strokes.count else { done?(.nothing); return }
        let groups = HandwritingTidier.prepare(Array(strokes[start...]), baseIndex: start)
        guard !groups.isEmpty else { done?(.unreadable); return }
        let expected = strokes.count
        let style = settings?.tidyStyle ?? .handwriting
        Task.detached(priority: .userInitiated) { [weak self] in
            let results = HandwritingTidier.recognize(groups, strict: !all)
            await MainActor.run {
                guard let self else { return }
                let outcome = self.apply(results, expectedStrokes: expected, start: start, style: style)
                done?(outcome)
            }
        }
    }

    private func apply(_ results: [HandwritingTidier.Result], expectedStrokes: Int, start: Int,
                       style: TidyStyle) -> TidyOutcome {
        // You kept writing (or erased) meanwhile: look at these strokes again after the
        // next pause.
        guard canvas.drawing.strokes.count == expectedStrokes else {
            considered = min(considered, start)
            return .busy
        }
        guard !results.isEmpty else { return .unreadable }
        let before = (pageDrawing, texts)
        let strokes = pageDrawing.strokes
        var removed = Set<Int>()
        var added: [InkText] = []
        for r in results {
            removed.formUnion(r.indices)
            let original = PKDrawing(strokes: r.indices.map { strokes[$0] })
            let n = CGRect(x: r.rect.minX / pageSize.width, y: r.rect.minY / pageSize.height,
                           width: r.rect.width / pageSize.width, height: r.rect.height / pageSize.height)
            added.append(InkText(id: UUID(), text: r.text, rect: n, colorHex: r.color.hexString, style: style,
                                 lines: r.lines, original: original.dataRepresentation()))
        }
        let kept = strokes.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        replace(drawing: PKDrawing(strokes: kept), texts: texts + added, undoFrom: before, name: "Tidy Handwriting")
        considered = kept.count
        return .tidied(added.count)
    }

    /// Swaps in a new page state (page points) and registers undo back to `before`.
    private func replace(drawing: PKDrawing, texts newTexts: [InkText], undoFrom before: (PKDrawing, [InkText]),
                         name: String) {
        undo.registerUndo(withTarget: self) { view in
            MainActor.assumeIsolated {
                let current = (view.pageDrawing, view.texts)
                view.replace(drawing: before.0, texts: before.1, undoFrom: current, name: name)
            }
        }
        undo.setActionName(name)
        setDrawing(drawing.transformed(using: toView))
        considered = min(considered, canvas.drawing.strokes.count)
        texts = newTexts
        layoutLabels()
        saveNow()
    }

    /// Erases everything on this page (undoable).
    func clear() {
        let shapes = shapeView.shapes
        guard pending == nil, !(canvas.drawing.strokes.isEmpty && texts.isEmpty && shapes.isEmpty) else { return }
        replace(drawing: PKDrawing(), texts: [], undoFrom: (pageDrawing, texts), name: "Clear Page")
        if !shapes.isEmpty {
            shapeView.setShapes([])
            shapesChanged([], undoFrom: shapes)
        }
    }

    private func restoreHandwriting(_ id: UUID) {
        guard let item = texts.first(where: { $0.id == id }) else { return }
        var strokes = pageDrawing.strokes
        if let data = item.original, let original = try? PKDrawing(data: data) { strokes += original.strokes }
        replace(drawing: PKDrawing(strokes: strokes), texts: texts.filter { $0.id != id },
                undoFrom: (pageDrawing, texts), name: "Restore Handwriting")
    }

    private func deleteText(_ id: UUID) {
        replace(drawing: pageDrawing, texts: texts.filter { $0.id != id }, undoFrom: (pageDrawing, texts),
                name: "Delete Text")
    }

    // MARK: Tidied text

    private func layoutLabels() {
        let ids = Set(texts.map(\.id))
        for (id, label) in labels where !ids.contains(id) {
            label.removeFromSuperview()
            labels[id] = nil
        }
        guard bounds.width > 1 else { return }
        for item in texts {
            let label: InkTextLabel
            if let existing = labels[item.id] {
                label = existing
            } else {
                label = InkTextLabel()
                label.onRestore = { [weak self] in self?.restoreHandwriting($0) }
                label.onDelete = { [weak self] in self?.deleteText($0) }
                label.isUserInteractionEnabled = canvas.isUserInteractionEnabled
                addSubview(label)
                labels[item.id] = label
            }
            let frame = CGRect(x: item.rect.minX * bounds.width, y: item.rect.minY * bounds.height,
                               width: item.rect.width * bounds.width, height: item.rect.height * bounds.height)
            label.configure(item, frame: frame.insetBy(dx: -frame.height * 0.1, dy: -frame.height * 0.05))
        }
    }
}

/// Tidied text on the page. Long-press for "Restore handwriting", "Copy" or "Delete".
final class InkTextLabel: UILabel, UIContextMenuInteractionDelegate {
    private var item: InkText?
    var onRestore: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 0
        adjustsFontSizeToFitWidth = true
        minimumScaleFactor = 0.2
        baselineAdjustment = .alignCenters
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ item: InkText, frame: CGRect) {
        self.item = item
        guard frame.isFiniteRect else { isHidden = true; return }
        isHidden = false
        self.frame = frame
        text = item.text
        textColor = UIColor(hex: item.colorHex) ?? .label
        let lineHeight = frame.height / CGFloat(max(item.lines, 1))
        let size = lineHeight * 0.72
        font = item.style.font(size: size.isFinite ? max(size, 4) : 12)
        accessibilityLabel = item.text
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let item else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = []
            if item.original != nil {
                actions.append(UIAction(title: "Restore handwriting", image: UIImage(systemName: "scribble")) { _ in
                    self?.onRestore?(item.id)
                })
            }
            actions.append(UIAction(title: "Copy text", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = item.text
            })
            actions.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self?.onDelete?(item.id)
            })
            return UIMenu(children: actions)
        }
    }
}
