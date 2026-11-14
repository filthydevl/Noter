import UIKit

/// The shapes on one page, drawn above its ink. With a shape tool picked, the Pencil
/// drags out a new shape (fingers still scroll); the shape you just drew or tapped shows
/// handles: drag a handle (finger or Pencil) to reshape it, drag the shape itself to move
/// it, or tap ✕ to delete it. With the eraser, touching a shape erases it.
@MainActor
final class ShapeOverlayView: UIView, UIGestureRecognizerDelegate {
    enum Mode: Equatable {
        case off
        case draw(ShapeKind)
        case erase
    }

    var mode: Mode = .off {
        didSet {
            guard mode != oldValue else { return }
            if case .draw = mode {} else { selected = nil }
            refresh()
        }
    }

    private(set) var shapes: [InkShape] = []
    /// The displayed page's size in points.
    var pageSize: CGSize = CGSize(width: 1, height: 1)
    /// The new shape's color (#RRGGBBAA) and line width in this view's points.
    var style: (() -> (colorHex: String, width: CGFloat))?
    /// A finished change, to save and make undoable.
    var onCommit: ((_ before: [InkShape], _ after: [InkShape]) -> Void)?

    private var layers: [UUID: CAShapeLayer] = [:]
    private let handleLayer = CAShapeLayer()
    private let deleteButton = UIButton(type: .system)
    private var selected: UUID? { didSet { if selected != oldValue { refresh() } } }

    private enum Drag {
        case create(UUID)
        case move(UUID, from: CGPoint, original: InkShape)
        case handle(UUID, index: Int, original: InkShape)
        case erase
    }
    private var drag: Drag?
    private var before: [InkShape] = []
    private var touchStart: CGPoint = .zero
    private var touchType: UITouch.TouchType = .direct

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        handleLayer.fillColor = UIColor.white.cgColor
        handleLayer.strokeColor = UIColor.systemBlue.cgColor
        handleLayer.lineWidth = 2
        handleLayer.zPosition = 10
        layer.addSublayer(handleLayer)

        deleteButton.setImage(UIImage(systemName: "xmark.circle.fill",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)), for: .normal)
        deleteButton.tintColor = .systemRed
        deleteButton.backgroundColor = .white
        deleteButton.layer.cornerRadius = 15
        deleteButton.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        deleteButton.accessibilityLabel = "Delete shape"
        deleteButton.addAction(UIAction { [weak self] _ in self?.deleteSelected() }, for: .touchUpInside)
        deleteButton.isHidden = true
        addSubview(deleteButton)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Replaces the shapes without making an undo step (load, undo, clear).
    func setShapes(_ new: [InkShape]) {
        shapes = new
        if let s = selected, !new.contains(where: { $0.id == s }) { selected = nil }
        refresh()
    }

    // MARK: Geometry

    /// View points per page point.
    private var unit: CGFloat { bounds.width / max(pageSize.width, 1) }

    private func toView(_ n: CGPoint) -> CGPoint { CGPoint(x: n.x * bounds.width, y: n.y * bounds.height) }

    private func toPage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x / max(bounds.width, 1), 0), 1), y: min(max(p.y / max(bounds.height, 1), 0), 1))
    }

    private func path(_ s: InkShape) -> CGPath { s.path(in: bounds.size, unit: unit) }

    /// The handles of a shape, in this view: its two ends, or its box's four corners
    /// (clockwise from top-left).
    private func handles(_ s: InkShape) -> [CGPoint] {
        let p = toView(s.a), q = toView(s.b)
        if s.kind.isLine { return [p, q] }
        let box = CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
        return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
    }

    private func handle(at point: CGPoint) -> Int? {
        guard let s = selectedShape else { return nil }
        let hs = handles(s)
        let best = hs.indices.min { hypot(hs[$0].x - point.x, hs[$0].y - point.y) < hypot(hs[$1].x - point.x, hs[$1].y - point.y) }
        guard let i = best, hypot(hs[i].x - point.x, hs[i].y - point.y) <= 24 else { return nil }
        return i
    }

    /// The top shape under a point: near its outline, or inside the selected one.
    private func shape(at point: CGPoint) -> InkShape? {
        for s in shapes.reversed() {
            let band = path(s).copy(strokingWithWidth: s.width * unit + 24, lineCap: .round, lineJoin: .round,
                                    miterLimit: 1)
            if band.contains(point) { return s }
            if s.id == selected, !s.kind.isLine, path(s).contains(point) { return s }
        }
        return nil
    }

    private var selectedShape: InkShape? { shapes.first { $0.id == selected } }

    // MARK: Drawing

    override func layoutSubviews() {
        super.layoutSubviews()
        refresh()
    }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ids = Set(shapes.map(\.id))
        for (id, l) in layers where !ids.contains(id) {
            l.removeFromSuperlayer()
            layers[id] = nil
        }
        for s in shapes {
            let l: CAShapeLayer
            if let existing = layers[s.id] {
                l = existing
            } else {
                l = CAShapeLayer()
                l.fillColor = nil
                l.lineCap = .round
                l.lineJoin = .round
                layer.insertSublayer(l, below: handleLayer)
                layers[s.id] = l
            }
            l.frame = bounds
            l.path = path(s)
            l.strokeColor = (UIColor(hex: s.colorHex) ?? .black).cgColor
            l.lineWidth = max(s.width * unit, 0.5)
        }
        handleLayer.frame = bounds
        if case .draw = mode, let s = selectedShape {
            let dots = CGMutablePath()
            for h in handles(s) { dots.addEllipse(in: CGRect(x: h.x - 7, y: h.y - 7, width: 14, height: 14)) }
            handleLayer.path = dots
            let hs = handles(s)
            let top = hs.min { $0.y < $1.y } ?? .zero
            let right = hs.map(\.x).max() ?? 0
            deleteButton.center = CGPoint(x: min(right + 22, bounds.width - 15), y: max(top.y - 22, 15))
            deleteButton.isHidden = false
            bringSubviewToFront(deleteButton)
        } else {
            handleLayer.path = nil
            deleteButton.isHidden = true
        }
        CATransaction.commit()
    }

    // MARK: Touches

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        switch mode {
        case .off: return false
        case .draw: return bounds.contains(point)
        case .erase: return shape(at: point) != nil
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.view is UIControl { return false } // the ✕ button
        touchStart = touch.location(in: self)
        touchType = touch.type
        return true
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g.view === self else { return super.gestureRecognizerShouldBegin(g) }
        switch mode {
        case .off:
            return false
        case .erase:
            return shape(at: touchStart) != nil
        case .draw:
            if g is UITapGestureRecognizer { return true }
            // Fingers only grab a handle or a shape; anywhere else they scroll the page.
            return handle(at: touchStart) != nil || shape(at: touchStart) != nil || touchType == .pencil
        }
    }

    /// While a handle or shape is being dragged, the page doesn't scroll.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        g is UIPanGestureRecognizer && other is UIPanGestureRecognizer && other.view is UIScrollView
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let point = g.location(in: self)
        switch mode {
        case .off:
            break
        case .erase:
            if let s = shape(at: point) { remove(s.id) }
        case .draw:
            selected = shape(at: point)?.id
        }
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let point = g.location(in: self)
        switch g.state {
        case .began:
            before = shapes
            if mode == .erase {
                drag = .erase
                if let s = shape(at: touchStart) { shapes.removeAll { $0.id == s.id } }
            } else if let i = handle(at: touchStart), let s = selectedShape {
                drag = .handle(s.id, index: i, original: s)
            } else if let s = shape(at: touchStart) {
                selected = s.id
                drag = .move(s.id, from: touchStart, original: s)
            } else if case .draw(let kind) = mode {
                let st = style?() ?? (colorHex: "#1A1A1AFF", width: 3)
                let start = toPage(touchStart)
                let s = InkShape(id: UUID(), kind: kind, a: start, b: toPage(point), colorHex: st.colorHex,
                                 width: st.width / max(unit, 0.01))
                shapes.append(s)
                selected = s.id
                drag = .create(s.id)
            }
            refresh()
        case .changed:
            update(to: point)
        case .ended:
            update(to: point)
            finish()
        default:
            shapes = before
            drag = nil
            refresh()
        }
    }

    private func update(to point: CGPoint) {
        guard let drag else { return }
        switch drag {
        case .erase:
            if let s = shape(at: point) { shapes.removeAll { $0.id == s.id } }
        case .create(let id):
            modify(id) { $0.b = toPage(point) }
        case .move(let id, let from, let original):
            let dx = (point.x - from.x) / max(bounds.width, 1), dy = (point.y - from.y) / max(bounds.height, 1)
            modify(id) {
                $0.a = CGPoint(x: original.a.x + dx, y: original.a.y + dy)
                $0.b = CGPoint(x: original.b.x + dx, y: original.b.y + dy)
            }
        case .handle(let id, let index, let original):
            let p = toPage(point)
            if original.kind.isLine {
                modify(id) { if index == 0 { $0.a = p } else { $0.b = p } }
            } else {
                // The opposite corner stays put.
                let corners = handles(original).map { self.toPage($0) }
                let fixed = corners[(index + 2) % 4]
                modify(id) { $0.a = fixed; $0.b = p }
            }
        }
        refresh()
    }

    private func modify(_ id: UUID, _ change: (inout InkShape) -> Void) {
        guard let i = shapes.firstIndex(where: { $0.id == id }) else { return }
        change(&shapes[i])
    }

    private func finish() {
        if case .create(let id) = drag, let s = shapes.first(where: { $0.id == id }) {
            // A tap-sized shape is a slip, not a shape.
            let p = toView(s.a), q = toView(s.b)
            if max(abs(q.x - p.x), abs(q.y - p.y)) < 8 {
                shapes.removeAll { $0.id == id }
                selected = nil
            }
        }
        drag = nil
        refresh()
        if shapes != before { onCommit?(before, shapes) }
    }

    private func remove(_ id: UUID) {
        let old = shapes
        shapes.removeAll { $0.id == id }
        if selected == id { selected = nil }
        refresh()
        onCommit?(old, shapes)
    }

    private func deleteSelected() {
        if let id = selected { remove(id) }
    }
}
