import UIKit

/// A highlight in the Text view: filled, or underlined (a circled word's definition).
struct TextHighlight {
    let range: NSRange
    let color: UIColor
    var underline = false
}

/// One book page of the transcript.
final class TranscriptCell: UICollectionViewCell {
    static let reuseID = "TranscriptCell"
    private static let speechColor = UIColor(named: "AccentColor") ?? .systemIndigo

    let header = UILabel()
    /// TextKit 1 so we can map pen positions to characters precisely.
    let textView = UITextView(usingTextLayoutManager: false)
    /// Drawn behind the text, bottom to top.
    private let highlightLayer = CALayer()
    private let markLayer = CAShapeLayer()
    private let markUnderlineLayer = CAShapeLayer()
    private let speechPhraseLayer = CAShapeLayer()
    private let speechWordLayer = CAShapeLayer()
    private let speechUnderlineLayer = CAShapeLayer()
    private let previewLayer = CAShapeLayer()
    private let flashLayer = CAShapeLayer()

    private(set) var page: LogicalPage?
    private var highlights: [TextHighlight] = []
    private var marks: [NSRange] = []
    private var flashRange: NSRange?
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
        speechWordLayer.fillColor = Self.speechColor.withAlphaComponent(0.30).cgColor
        speechUnderlineLayer.fillColor = Self.speechColor.withAlphaComponent(0.95).cgColor
        previewLayer.fillColor = UIColor.clear.cgColor
        markLayer.fillColor = UIColor.systemPurple.withAlphaComponent(0.16).cgColor
        markUnderlineLayer.fillColor = UIColor.systemPurple.withAlphaComponent(0.7).cgColor
        flashLayer.fillColor = Self.speechColor.withAlphaComponent(0.10).cgColor
        flashLayer.strokeColor = Self.speechColor.cgColor
        flashLayer.lineWidth = 2
        flashLayer.opacity = 0
        for (i, layer) in [highlightLayer, markLayer, markUnderlineLayer, speechPhraseLayer, speechWordLayer,
                           speechUnderlineLayer, previewLayer, flashLayer].enumerated() {
            textView.layer.insertSublayer(layer, at: UInt32(i))
        }

        // Overlay tints are stronger in dark mode (they sit on a dark background there).
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: TranscriptCell, _: UITraitCollection) in
            cell.setNeedsLayout()
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
        marks = []
        flashRange = nil
        speechToken = nil
        previewRange = nil
        withoutAnimation {
            highlightLayer.sublayers = nil
            markLayer.path = nil
            markUnderlineLayer.path = nil
            flashLayer.removeAllAnimations()
            flashLayer.path = nil
            previewLayer.path = nil
            speechPhraseLayer.path = nil
            speechWordLayer.path = nil
            speechUnderlineLayer.path = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Geometry depends on the final width, so redraw overlays after layout.
        withoutAnimation {
            for layer in [highlightLayer, markLayer, markUnderlineLayer, speechPhraseLayer, speechWordLayer,
                          speechUnderlineLayer, previewLayer, flashLayer] {
                layer.frame = textView.bounds
            }
        }
        redrawHighlights()
        redrawMarks()
        redrawFlash()
        redrawPreview()
        _ = drawSpeech()
    }

    // MARK: Content

    func configure(page: LogicalPage, header text: String, highlights: [TextHighlight],
                   skipped: [NSRange], marks: [NSRange], fontSize: CGFloat, appearance: TextAppearance) {
        self.page = page
        header.text = text
        header.textColor = appearance.theme.secondary
        if page.text.isEmpty {
            textView.attributedText = NSAttributedString(string: "No text on this page.",
                                                         attributes: appearance.noteAttributes(size: fontSize))
        } else {
            let body = NSMutableAttributedString(string: page.text,
                                                 attributes: appearance.bodyAttributes(size: fontSize))
            // Chapter / section headings.
            let heading = appearance.headingAttributes(size: fontSize)
            for r in page.headingRanges where NSMaxRange(r) <= body.length {
                body.addAttributes(heading, range: r)
            }
            // Text that read-aloud skips is dimmed.
            for r in skipped where NSMaxRange(r) <= body.length {
                body.addAttribute(.foregroundColor, value: appearance.theme.secondary, range: r)
            }
            textView.attributedText = body
        }
        applyHighlights(highlights)
        applyMarks(marks)
        setNeedsLayout()
    }

    func configurePlaceholder(header text: String, fontSize: CGFloat, appearance: TextAppearance) {
        page = nil
        header.text = text
        header.textColor = appearance.theme.secondary
        textView.attributedText = NSAttributedString(string: "Recognizing text…",
                                                     attributes: appearance.noteAttributes(size: fontSize))
        applyHighlights([])
        applyMarks([])
    }

    /// Questions found by the questions highlighter (shown when "Mark on pages" is on).
    func applyMarks(_ ranges: [NSRange]) {
        marks = ranges
        redrawMarks()
    }

    private func redrawMarks() {
        withoutAnimation {
            guard page != nil, !marks.isEmpty else {
                markLayer.path = nil
                markUnderlineLayer.path = nil
                return
            }
            let rects = marks.flatMap { textRects(for: $0) }
            let dark = traitCollection.userInterfaceStyle == .dark
            markLayer.fillColor = UIColor.systemPurple.resolvedColor(with: traitCollection)
                .withAlphaComponent(dark ? 0.32 : 0.16).cgColor
            markLayer.path = path(rects, radius: 3)
            markUnderlineLayer.path = path(rects.map {
                CGRect(x: $0.minX + 1, y: $0.maxY - 1.5, width: max($0.width - 2, 2), height: 1.5)
            }, radius: 0.75)
        }
    }

    /// Union of the glyph rects of a range (text view coordinates), for scrolling to it.
    func rect(for range: NSRange) -> CGRect? {
        let rects = textRects(for: range)
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Boxes the range and blinks it a few times so it's easy to spot.
    func flash(range: NSRange) {
        flashRange = range
        redrawFlash()
        flashLayer.removeAnimation(forKey: "flash")
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [0, 1, 0.15, 1, 0.15, 1, 0]
        blink.keyTimes = [0, 0.08, 0.28, 0.46, 0.64, 0.82, 1]
        blink.duration = 2.6
        flashLayer.opacity = 0
        flashLayer.add(blink, forKey: "flash")
    }

    private func redrawFlash() {
        withoutAnimation {
            guard let flashRange else {
                flashLayer.path = nil
                return
            }
            flashLayer.path = path(textRects(for: flashRange).map { $0.insetBy(dx: -4, dy: -3) }, radius: 6)
        }
    }

    func applyHighlights(_ highlights: [TextHighlight]) {
        self.highlights = highlights
        redrawHighlights()
    }

    private func redrawHighlights() {
        withoutAnimation {
            highlightLayer.sublayers = nil
            guard let page, !page.text.isEmpty else { return }
            for h in highlights {
                let shape = CAShapeLayer()
                shape.frame = highlightLayer.bounds
                let rects = textRects(for: h.range)
                if h.underline {
                    shape.fillColor = h.color.withAlphaComponent(0.9).cgColor
                    shape.path = path(rects.map { r in
                        CGRect(x: r.minX, y: r.maxY - 2.5, width: r.width, height: 2.5)
                    }, radius: 1)
                } else {
                    shape.fillColor = h.color.withAlphaComponent(0.42).cgColor
                    shape.path = path(rects, radius: 3)
                }
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

    /// The first word on the wrapped line at `y` (text view coordinates), for keeping the
    /// PDF and Text views on the same spot.
    func token(atLineY y: CGFloat) -> Int? {
        guard let page, !page.tokenRanges.isEmpty else { return nil }
        let lm = textView.layoutManager
        guard lm.numberOfGlyphs > 0 else { return nil }
        let glyph = lm.glyphIndex(for: CGPoint(x: 1, y: max(y, 0)), in: textView.textContainer)
        var line = NSRange()
        _ = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        let char = lm.characterIndexForGlyph(at: line.location)
        guard var token = page.tokenIndex(atUTF16: char) else { return nil }
        // tokenIndex gives the word at or before the line start; step onto this line.
        if page.tokenRanges[token].location < char, token + 1 < page.tokenRanges.count { token += 1 }
        return token
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
                speechUnderlineLayer.path = nil
                return
            }
            let phraseRects = textRects(for: page.textRange(for: phrase))
            let wordRects = textRects(for: page.tokenRanges[token])
            let dark = traitCollection.userInterfaceStyle == .dark
            let accent = Self.speechColor.resolvedColor(with: traitCollection)
            speechPhraseLayer.fillColor = accent.withAlphaComponent(dark ? 0.34 : 0.17).cgColor
            speechWordLayer.fillColor = accent.withAlphaComponent(dark ? 0.55 : 0.32).cgColor
            speechUnderlineLayer.fillColor = accent.withAlphaComponent(0.95).cgColor
            speechPhraseLayer.path = phraseRects.isEmpty ? nil : path(phraseRects, radius: 4)
            speechWordLayer.path = wordRects.isEmpty ? nil : path(wordRects, radius: 4)
            // A solid underline under the word being spoken (Speechify-style).
            let underlines = wordRects.map { r in
                CGRect(x: r.minX + 1, y: r.maxY - 2.5, width: max(r.width - 2, 2), height: 2.5)
            }
            speechUnderlineLayer.path = underlines.isEmpty ? nil : path(underlines, radius: 1.25)
            wordRect = wordRects.first ?? phraseRects.first
        }
        return wordRect
    }
}
