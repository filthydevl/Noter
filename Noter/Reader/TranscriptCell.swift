import UIKit

/// One book page of the transcript.
final class TranscriptCell: UICollectionViewCell {
    static let reuseID = "TranscriptCell"

    let header = UILabel()
    /// TextKit 1 so we can map pen positions to characters precisely.
    let textView = UITextView(usingTextLayoutManager: false)
    private let divider = UIView()
    private let previewLayer = CAShapeLayer()
    private let speechLineLayer = CAShapeLayer()
    private let speechWordLayer = CAShapeLayer()

    private(set) var page: LogicalPage?
    private var speechToken: Int?
    private var previewRange: NSRange?
    private var previewColor: UIColor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabel
        divider.backgroundColor = .separator

        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false // touches are handled by the list
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []

        for layer in [speechLineLayer, speechWordLayer, previewLayer] {
            layer.fillColor = UIColor.clear.cgColor
            textView.layer.insertSublayer(layer, at: 0)
        }

        for v in [divider, header, textView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        let bottom = textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -28)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            header.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            textView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottom,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        page = nil
        speechToken = nil
        previewRange = nil
        previewLayer.path = nil
        speechLineLayer.path = nil
        speechWordLayer.path = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for layer in [speechLineLayer, speechWordLayer, previewLayer] { layer.frame = textView.bounds }
        // Geometry depends on the final width, so redraw overlays after layout.
        redrawPreview()
        _ = drawSpeech()
    }

    // MARK: Content

    static func attributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
        let base = UIFont.systemFont(ofSize: size)
        let font = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = size * 0.32
        paragraph.paragraphSpacing = size * 0.8
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
            applyHighlights(highlights)
        }
        setNeedsLayout()
    }

    func configurePlaceholder(header text: String, fontSize: CGFloat) {
        page = nil
        header.text = text
        textView.attributedText = NSAttributedString(string: "Recognizing text…", attributes: [
            .font: UIFont.italicSystemFont(ofSize: fontSize * 0.8), .foregroundColor: UIColor.tertiaryLabel,
        ])
    }

    func applyHighlights(_ highlights: [(NSRange, UIColor)]) {
        guard let page, !page.text.isEmpty else { return }
        let storage = textView.textStorage
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: full)
        for (range, color) in highlights where NSMaxRange(range) <= storage.length {
            storage.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.45), range: range)
        }
        storage.endEditing()
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
        guard let range = previewRange, let color = previewColor, NSMaxRange(range) <= textView.textStorage.length else {
            previewLayer.path = nil
            return
        }
        previewLayer.fillColor = color.withAlphaComponent(0.35).cgColor
        previewLayer.path = path(for: range)
    }

    private func path(for range: NSRange) -> CGPath {
        let lm = textView.layoutManager
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let path = UIBezierPath()
        lm.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textView.textContainer
        ) { rect, _ in
            path.append(UIBezierPath(roundedRect: rect.insetBy(dx: -2, dy: 0), cornerRadius: 3))
        }
        return path.cgPath
    }

    // MARK: Read-aloud indicator

    /// Shows which line (and word) is being read. Returns the line rect in text view
    /// coordinates.
    @discardableResult
    func setSpeech(token: Int?) -> CGRect? {
        speechToken = token
        return drawSpeech()
    }

    private func drawSpeech() -> CGRect? {
        guard let token = speechToken, let page, token < page.tokenRanges.count,
              NSMaxRange(page.tokenRanges[token]) <= textView.textStorage.length else {
            speechLineLayer.path = nil
            speechWordLayer.path = nil
            return nil
        }
        let lm = textView.layoutManager
        let glyphs = lm.glyphRange(forCharacterRange: page.tokenRanges[token], actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let line = lm.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let word = lm.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)

        speechLineLayer.path = UIBezierPath(roundedRect: line.insetBy(dx: -8, dy: -2), cornerRadius: 6).cgPath
        speechLineLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        speechLineLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.35).cgColor
        speechLineLayer.lineWidth = 1
        speechWordLayer.path = UIBezierPath(roundedRect: word.insetBy(dx: -2, dy: 0), cornerRadius: 4).cgPath
        speechWordLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.22).cgColor
        return line
    }
}
