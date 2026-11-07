import UIKit
import PDFKit

/// Drawn above one PDF page (PDFKit moves and zooms it with the page): question marks,
/// the read-along sentence / word, the pen preview, and the blinking "here it is" box.
/// Using plain layers instead of PDF annotations keeps PDFKit from re-rendering the
/// page on every spoken word.
///
/// All rects are normalized to the displayed page (0...1, origin top-left).
final class PDFPageOverlay: UIView {
    private weak var pdfView: PDFView?
    private let page: PDFPage
    private let geometry: PageGeometry

    private var markRects: [CGRect] = []
    private var phraseRects: [CGRect] = []
    private var wordRect: CGRect?
    private var previewRects: [CGRect] = []
    private var previewColor: UIColor?
    private var flashRects: [CGRect] = []

    private let markLayer = CAShapeLayer()
    private let markUnderlineLayer = CAShapeLayer()
    private let phraseLayer = CAShapeLayer()
    private let wordLayer = CAShapeLayer()
    private let underlineLayer = CAShapeLayer()
    private let previewLayer = CAShapeLayer()
    private let flashLayer = CAShapeLayer()

    /// The page's scribble layer (above the tints, so ink is on top).
    private(set) var ink: PageInkView?

    static let accent = UIColor(named: "AccentColor") ?? .systemIndigo
    /// The questions highlighter.
    static let markColor = UIColor.systemPurple

    init(page: PDFPage, pdfView: PDFView) {
        self.page = page
        self.pdfView = pdfView
        self.geometry = PageGeometry(page: page)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        markLayer.fillColor = Self.markColor.withAlphaComponent(0.16).cgColor
        markUnderlineLayer.fillColor = Self.markColor.withAlphaComponent(0.7).cgColor
        phraseLayer.fillColor = Self.accent.withAlphaComponent(0.16).cgColor
        wordLayer.fillColor = Self.accent.withAlphaComponent(0.30).cgColor
        underlineLayer.fillColor = Self.accent.withAlphaComponent(0.95).cgColor
        flashLayer.fillColor = Self.accent.withAlphaComponent(0.10).cgColor
        flashLayer.strokeColor = Self.accent.cgColor
        flashLayer.opacity = 0
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
        setNeedsLayout()
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
        for l in [markLayer, markUnderlineLayer, phraseLayer, wordLayer, underlineLayer, previewLayer, flashLayer] {
            l.frame = bounds
        }
        guard window != nil else { return }

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
