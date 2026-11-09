import UIKit
import PDFKit

/// Drawn above one PDF page (PDFKit moves and zooms it with the page): your highlights,
/// question marks, the read-along sentence / word, the pen preview, and the blinking
/// "here it is" box. Using plain layers instead of PDF annotations keeps PDFKit from
/// re-rendering the page on every change (and from tracking every highlight for the
/// pointer, which was slow and flooded the log).
///
/// All rects are normalized to the displayed page (0...1, origin top-left).
final class PDFPageOverlay: UIView {
    private weak var pdfView: PDFView?
    private let page: PDFPage
    private let geometry: PageGeometry

    private var highlightItems: [(rect: CGRect, color: UIColor, style: HighlightStyle)] = []
    private var markRects: [CGRect] = []
    private var phraseRects: [CGRect] = []
    private var wordRect: CGRect?
    private var previewRects: [CGRect] = []
    private var previewColor: UIColor?
    private var flashRects: [CGRect] = []

    /// One shape layer per highlight color, multiplied onto the page like a real
    /// highlighter so the print stays crisp and black.
    private let highlightContainer = CALayer()
    private var highlightLayers: [String: CAShapeLayer] = [:]
    private let markLayer = CAShapeLayer()
    private let markUnderlineLayer = CAShapeLayer()
    private let phraseLayer = CAShapeLayer()
    private let wordLayer = CAShapeLayer()
    private let underlineLayer = CAShapeLayer()
    private let previewLayer = CAShapeLayer()
    private let flashLayer = CAShapeLayer()

    /// The page's scribble layer (above the tints, so ink is on top).
    private(set) var ink: PageInkView?
    /// Scribbling: the ink layer takes the pencil. Otherwise touches go through to the
    /// PDF, except on the ✓ button.
    var inkActive = false
    /// The ✓ next to a circled word whose definition you're underlining.
    private let confirmButton = UIButton(type: .system)
    private var confirmRect: CGRect?
    var onConfirm: (() -> Void)?

    static let accent = UIColor(named: "AccentColor") ?? .systemIndigo
    /// The questions highlighter.
    static let markColor = UIColor.systemPurple

    init(page: PDFPage, pdfView: PDFView) {
        self.page = page
        self.pdfView = pdfView
        self.geometry = PageGeometry(page: page)
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        backgroundColor = .clear

        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "checkmark", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
        config.baseBackgroundColor = HighlightColor.maroon.uiColor
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        confirmButton.configuration = config
        confirmButton.layer.shadowColor = UIColor.black.cgColor
        confirmButton.layer.shadowOpacity = 0.25
        confirmButton.layer.shadowRadius = 4
        confirmButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        confirmButton.accessibilityLabel = "Save definition"
        confirmButton.isHidden = true
        confirmButton.addAction(UIAction { [weak self] _ in self?.onConfirm?() }, for: .primaryActionTriggered)

        markLayer.fillColor = Self.markColor.withAlphaComponent(0.16).cgColor
        markUnderlineLayer.fillColor = Self.markColor.withAlphaComponent(0.7).cgColor
        phraseLayer.fillColor = Self.accent.withAlphaComponent(0.16).cgColor
        wordLayer.fillColor = Self.accent.withAlphaComponent(0.30).cgColor
        underlineLayer.fillColor = Self.accent.withAlphaComponent(0.95).cgColor
        flashLayer.fillColor = Self.accent.withAlphaComponent(0.10).cgColor
        flashLayer.strokeColor = Self.accent.cgColor
        flashLayer.opacity = 0
        highlightContainer.compositingFilter = "multiplyBlendMode"
        layer.addSublayer(highlightContainer)
        for l in [markLayer, markUnderlineLayer, phraseLayer, wordLayer, underlineLayer, previewLayer, flashLayer] {
            layer.addSublayer(l)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: State

    func attachInk(_ view: PageInkView) {
        ink?.removeFromSuperview()
        ink = view
        addSubview(view)
        addSubview(confirmButton) // above the ink
        setNeedsLayout()
    }

    /// Shows the ✓ next to the circled word at `rect` (normalized), or hides it.
    func setConfirm(_ rect: CGRect?) {
        confirmRect = rect
        if confirmButton.superview == nil { addSubview(confirmButton) }
        setNeedsLayout()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !confirmButton.isHidden, confirmButton.frame.insetBy(dx: -10, dy: -10).contains(point) {
            return confirmButton
        }
        return inkActive ? super.hitTest(point, with: event) : nil
    }

    func setHighlights(_ items: [(rect: CGRect, color: UIColor, style: HighlightStyle)]) {
        highlightItems = items
        redraw()
    }

    func setMarks(_ rects: [CGRect]) {
        markRects = rects
        redraw()
    }

    func setSpeech(phrase: [CGRect], word: CGRect?) {
        phraseRects = phrase
        wordRect = word
        redraw()
    }

    func setPreview(_ rects: [CGRect], color: UIColor?) {
        previewRects = rects
        previewColor = color
        redraw()
    }

    /// Boxes the rects and blinks them a few times.
    func flash(_ rects: [CGRect]) {
        flashRects = rects
        redraw()
        flashLayer.removeAnimation(forKey: "flash")
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [0, 1, 0.15, 1, 0.15, 1, 0]
        blink.keyTimes = [0, 0.08, 0.28, 0.46, 0.64, 0.82, 1]
        blink.duration = 2.6
        flashLayer.opacity = 0
        flashLayer.add(blink, forKey: "flash")
    }

    // MARK: Drawing

    override func layoutSubviews() {
        super.layoutSubviews()
        ink?.frame = bounds
        redraw()
        layoutConfirm()
    }

    /// Just right of the circled word (left of it if there's no room), centred on it.
    private func layoutConfirm() {
        guard let n = confirmRect, let r = viewRect(n.circledWordEllipse) else {
            confirmButton.isHidden = true
            return
        }
        let size: CGFloat = 40
        var x = r.maxX + 8
        if x + size > bounds.maxX { x = r.minX - 8 - size }
        let y = min(max(r.midY - size / 2, bounds.minY), bounds.maxY - size)
        confirmButton.frame = CGRect(x: max(x, bounds.minX), y: y, width: size, height: size)
        confirmButton.isHidden = false
        bringSubviewToFront(confirmButton)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    /// Normalized page rect → this view's coordinates, via PDFKit's own conversion so
    /// rotation and zoom are handled for us.
    private func viewRect(_ n: CGRect) -> CGRect? {
        guard let pdfView, window != nil else { return nil }
        let inPDFView = pdfView.convert(geometry.pageRect(fromNormalized: n), from: page)
        let r = convert(inPDFView, from: pdfView)
        return r.isNull || r.isInfinite ? nil : r
    }

    private func path(_ rects: [CGRect], radius: CGFloat) -> CGPath? {
        guard !rects.isEmpty else { return nil }
        let p = UIBezierPath()
        for r in rects { p.append(UIBezierPath(roundedRect: r, cornerRadius: radius)) }
        return p.cgPath
    }

    /// A thin bar along the bottom of each rect.
    private func underlines(_ rects: [CGRect], ratio: CGFloat) -> [CGRect] {
        rects.map { r in
            let h = max(r.height * ratio, 1)
            return CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
        }
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for l in [highlightContainer, markLayer, markUnderlineLayer, phraseLayer, wordLayer, underlineLayer,
                  previewLayer, flashLayer] {
            l.frame = bounds
        }
        guard window != nil else { return }

        // Highlights: hug the words — a touch wider than the text, slightly shorter than
        // the OCR box, so highlights on neighbouring lines never touch.
        // A circled word gets a circle around it, its definition an underline.
        var byColor: [String: (color: UIColor, rects: [CGRect])] = [:]
        for item in highlightItems {
            guard var r = viewRect(item.rect.insetBy(dx: -0.002, dy: item.rect.height * 0.04)) else { continue }
            let suffix: String
            switch item.style {
            case .fill:
                suffix = ""
            case .underline:
                let h = max(r.height * 0.12, 1.5)
                r = CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
                suffix = "-u"
            case .circle:
                // Highlighted as usual, plus a circle around it.
                byColor[item.color.hexString, default: (color: item.color, rects: [])].rects.append(r)
                r = r.circledWordEllipse
                suffix = "-c"
            }
            let key = item.color.hexString + suffix
            byColor[key, default: (color: item.color, rects: [])].rects.append(r)
        }
        for (key, l) in highlightLayers where byColor[key] == nil {
            l.removeFromSuperlayer()
            highlightLayers[key] = nil
        }
        for (key, entry) in byColor {
            let l: CAShapeLayer
            if let existing = highlightLayers[key] {
                l = existing
            } else {
                l = CAShapeLayer()
                highlightContainer.addSublayer(l)
                highlightLayers[key] = l
            }
            l.frame = bounds
            if key.hasSuffix("-c") {
                // Circles: an outline the word sits inside.
                let p = UIBezierPath()
                for r in entry.rects { p.append(UIBezierPath(ovalIn: r)) }
                let avgH = entry.rects.map(\.height).reduce(0, +) / CGFloat(max(entry.rects.count, 1))
                l.path = p.cgPath
                l.fillColor = nil
                l.strokeColor = entry.color.withAlphaComponent(0.9).cgColor
                l.lineWidth = max(avgH * 0.07, 1.5)
            } else {
                l.strokeColor = nil
                l.fillColor = entry.color.withAlphaComponent(key.hasSuffix("-u") ? 0.95 : 0.5).cgColor
                l.path = path(entry.rects, radius: 1.5)
            }
        }

        let marks = markRects.compactMap { viewRect($0.insetBy(dx: -0.001, dy: $0.height * 0.04)) }
        markLayer.path = path(marks, radius: 2)
        markUnderlineLayer.path = path(underlines(marks, ratio: 0.07), radius: 0.5)

        phraseLayer.path = path(phraseRects.compactMap { viewRect($0.insetBy(dx: -0.002, dy: $0.height * 0.04)) },
                                radius: 3)
        let word = wordRect.flatMap { viewRect($0.insetBy(dx: -0.001, dy: $0.height * 0.04)) }
        wordLayer.path = word.flatMap { path([$0], radius: 3) }
        underlineLayer.path = word.flatMap { path(underlines([$0], ratio: 0.1), radius: 1) }

        previewLayer.fillColor = (previewColor ?? .clear).withAlphaComponent(0.35).cgColor
        previewLayer.path = path(previewRects.compactMap { viewRect($0.insetBy(dx: -0.002, dy: $0.height * 0.04)) },
                                 radius: 2)

        let boxes = flashRects.compactMap { viewRect($0) }.map { r in
            r.insetBy(dx: -max(r.height * 0.25, 3), dy: -max(r.height * 0.18, 2))
        }
        flashLayer.lineWidth = max((boxes.first?.height ?? 10) * 0.08, 1.5)
        flashLayer.path = path(boxes, radius: max((boxes.first?.height ?? 10) * 0.25, 4))
    }
}
