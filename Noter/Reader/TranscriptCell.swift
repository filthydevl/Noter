import UIKit

/// One book page of the transcript.
final class TranscriptCell: UICollectionViewCell {
    static let reuseID = "TranscriptCell"
    private static let speechColor = UIColor(named: "AccentColor") ?? .systemIndigo

    let header = UILabel()
    /// TextKit 1 so we can map pen positions to characters precisely.
    let textView = UITextView(usingTextLayoutManager: false)
    /// Drawn behind the text, bottom to top.
    private let highlightLayer = CALayer()
    private let speechPhraseLayer = CAShapeLayer()
    private let speechWordLayer = CAShapeLayer()
    private let previewLayer = CAShapeLayer()

    private(set) var page: LogicalPage?
    private var highlights: [(NSRange, UIColor)] = []
    private var speechToken: Int?
    private var previewRange: NSRange?
    private var previewColor: UIColor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .tertiaryLabel

        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false // touches are handled by the list
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []

        speechPhraseLayer.fillColor = Self.speechColor.withAlphaComponent(0.13).cgColor
        speechWordLayer.fillColor = Self.speechColor.withAlphaComponent(0.22).cgColor
        previewLayer.fillColor = UIColor.clear.cgColor
        for (i, layer) in [highlightLayer, speechPhraseLayer, speechWordLayer, previewLayer].enumerated() {
            textView.layer.insertSublayer(layer, at: UInt32(i))
        }

        for v in [header, textView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        let bottom = textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -28)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            textView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottom,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        page = nil
        highlights = []
        speechToken = nil
        previewRange = nil
        withoutAnimation {
            highlightLayer.sublayers = nil
            previewLayer.path = nil
            speechPhraseLayer.path = nil
            speechWordLayer.path = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Geometry depends on the final width, so redraw overlays after layout.
        withoutAnimation {
            for layer in [highlightLayer, speechPhraseLayer, speechWordLayer, previewLayer] {
                layer.frame = textView.bounds
            }
        }
        redrawHighlights()
        redrawPreview()
        _ = drawSpeech()
    }

    // MARK: Content

    static func attributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
        let base = UIFont.systemFont(ofSize: size)
        let font = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = size * 0.38
        paragraph.paragraphSpacing = size * 0.9
        return [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
    }

    func configure(page: LogicalPage, header text: String, highlights: [(NSRange, UIColor)], fontSize: CGFloat) {
        self.page = page
        header.text = text
        if page.text.isEmpty {
            textView.attributedText = NSAttributedString(string: "No text on this page.", attributes: [
                .font: UIFont.italicSystemFont(ofSize: fontSize * 0.8), .foregroundColor: UIColor.tertiaryLabel,
            ])
        } else {
            textView.attributedText = NSAttributedString(string: page.text, attributes: Self.attributes(fontSize))
        }
        applyHighlights(highlights)
        setNeedsLayout()
    }

    func configurePlaceholder(header text: String, fontSize: CGFloat) {
        page = nil
        header.text = text
        textView.attributedText = NSAttributedString(string: "Recognizing text…", attributes: [
            .font: UIFont.italicSystemFont(ofSize: fontSize * 0.8), .foregroundColor: UIColor.tertiaryLabel,
        ])
        applyHighlights([])
    }

    func applyHighlights(_ highlights: [(NSRange, UIColor)]) {
        self.highlights = highlights
        redrawHighlights()
    }

    private func redrawHighlights() {
        withoutAnimation {
            highlightLayer.sublayers = nil
            guard let page, !page.text.isEmpty else { return }
            for (range, color) in highlights {
                let shape = CAShapeLayer()
                shape.frame = highlightLayer.bounds
                shape.fillColor = color.withAlphaComponent(0.42).cgColor
                shape.path = path(textRects(for: range), radius: 3)
                highlightLayer.addSublayer(shape)
            }
        }
    }

    // MARK: Geometry

    /// One rect per wrapped line covering only the glyphs of `range` — from the font's
    /// ascender to its descender, not the extra line spacing — in text view coordinates.
    private func textRects(for range: NSRange) -> [CGRect] {
        let storage = textView.textStorage
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return [] }
        let lm = textView.layoutManager
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return [] }
        var rects: [CGRect] = []
        lm.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, container, lineGlyphs, _ in
            let r = NSIntersectionRange(lineGlyphs, glyphs)
            guard r.length > 0 else { return }
            var box = lm.boundingRect(forGlyphRange: r, in: container)
            let char = lm.characterIndexForGlyph(at: r.location)
            let font = storage.attribute(.font, at: min(char, storage.length - 1), effectiveRange: nil) as? UIFont
                ?? .systemFont(ofSize: 17)
            let baseline = lineRect.minY + lm.location(forGlyphAt: r.location).y
            box.origin.y = baseline - font.ascender
            box.size.height = font.ascender - font.descender
            rects.append(box.insetBy(dx: -1.5, dy: box.height * 0.04))
        }
        return rects
    }

    private func path(_ rects: [CGRect], radius: CGFloat) -> CGPath {
        let path = UIBezierPath()
        for r in rects { path.append(UIBezierPath(roundedRect: r, cornerRadius: radius)) }
        return path.cgPath
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Pen → words

    var textWidth: CGFloat { max(textView.textContainer.size.width, textView.bounds.width, 1) }

    /// The word under a point (in text view coordinates), tolerant of a slightly high
    /// or low pen. `line` is the y of the wrapped line, so it sorts in reading order.
    func hit(at point: CGPoint) -> StrokeHit? {
        guard let page, !page.tokenRanges.isEmpty else { return nil }
        let lm = textView.layoutManager
        let tc = textView.textContainer
        guard lm.numberOfGlyphs > 0 else { return nil }
        let glyph = lm.glyphIndex(for: point, in: tc, fractionOfDistanceThroughGlyph: nil)
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let used = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        guard point.y >= lineRect.minY - 6, point.y <= lineRect.maxY + 6,
              point.x >= used.minX - 24, point.x <= used.maxX + 24 else { return nil }
        let char = lm.characterIndexForGlyph(at: glyph)
        guard let token = page.tokenIndex(atUTF16: char) else { return nil }
        return StrokeHit(line: Int(lineRect.minY.rounded()), token: token, x: point.x)
    }

    func showPreview(_ range: NSRange?, color: UIColor?) {
        previewRange = range
        previewColor = color
        redrawPreview()
    }

    private func redrawPreview() {
        withoutAnimation {
            guard let range = previewRange, let color = previewColor else {
                previewLayer.path = nil
                return
            }
            previewLayer.fillColor = color.withAlphaComponent(0.3).cgColor
            previewLayer.path = path(textRects(for: range), radius: 3)
        }
    }

    // MARK: Read-aloud indicator

    /// Tints the sentence / phrase being read, with the current word a little stronger.
    /// Returns the current word's rect in text view coordinates (for scrolling).
    @discardableResult
    func setSpeech(token: Int?) -> CGRect? {
        speechToken = token
        return drawSpeech()
    }

    private func drawSpeech() -> CGRect? {
        var wordRect: CGRect?
        withoutAnimation {
            guard let token = speechToken, let page, token < page.tokenRanges.count,
                  let phrase = page.phraseRange(containing: token) else {
                speechPhraseLayer.path = nil
                speechWordLayer.path = nil
                return
            }
            let phraseRects = textRects(for: page.textRange(for: phrase))
            let wordRects = textRects(for: page.tokenRanges[token])
            speechPhraseLayer.path = phraseRects.isEmpty ? nil : path(phraseRects, radius: 4)
            speechWordLayer.path = wordRects.isEmpty ? nil : path(wordRects, radius: 4)
            wordRect = wordRects.first ?? phraseRects.first
        }
        return wordRect
    }
}
