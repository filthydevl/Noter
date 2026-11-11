import UIKit

/// A highlight in the Text view: filled, circled (a circled word) or underlined (its
/// definition).
struct TextHighlight {
    let range: NSRange
    let color: UIColor
    var style: HighlightStyle = .fill
}

/// A small button that still takes taps a little way around it.
final class RoomyButton: UIButton, UIGestureRecognizerDelegate {
    override init(frame: CGRect) {
        super.init(frame: frame)
        // Its own tap (finger or pencil), so the text view's gestures can't swallow it.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func tapped() { sendActions(for: .primaryActionTriggered) }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -14, dy: -14).contains(point)
    }
}

/// One book page of the transcript.
final class TranscriptCell: UICollectionViewCell {
    static let reuseID = "TranscriptCell"

    /// In the two-page layout the cell measures its own height (the list layout does it
    /// for itself).
    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutAttributes {
        guard attributes is TwoPageLayout.Attributes else { return super.preferredLayoutAttributesFitting(attributes) }
        let a = attributes.copy() as! UICollectionViewLayoutAttributes
        // Measuring a whole page of text is slow: once per text and width (read-aloud
        // scrolling asks again and again).
        let width = attributes.frame.width
        if let m = measured, abs(m.width - width) < 0.5 {
            a.frame.size.height = m.height
            return a
        }
        let size = contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        a.frame.size.height = ceil(size.height)
        measured = (width, a.frame.size.height)
        return a
    }
    /// This page's measured height at a width (two-page layout).
    private var measured: (width: CGFloat, height: CGFloat)?
    /// The text width the overlays were last measured at (-1: measure again).
    private var overlayWidth: CGFloat = -1
    private static let speechColor = UIColor(named: "AccentColor") ?? .systemIndigo

    let header = UILabel()
    /// TextKit 1 so we can map pen positions to characters precisely.
    let textView = ReportingTextView(usingTextLayoutManager: false)
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
    /// The ✓ next to a circled word whose definition you're underlining.
    private let confirmButton = RoomyButton(type: .system)
    private var confirmRange: NSRange?
    var onConfirm: (() -> Void)?

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
        UIColor.styleFlash(flashLayer)
        flashLayer.lineWidth = 3
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
        // The text re-wraps when its width settles (a two-page column is narrower than
        // the list): measure the highlights again then, or they sit on the old lines.
        textView.onResize = { [weak self] in self?.redrawOverlays() }

        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "checkmark", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        config.baseBackgroundColor = HighlightColor.maroon.uiColor
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = .zero
        confirmButton.configuration = config
        confirmButton.layer.shadowColor = UIColor.black.cgColor
        confirmButton.layer.shadowOpacity = 0.25
        confirmButton.layer.shadowRadius = 4
        confirmButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        confirmButton.accessibilityLabel = "Save definition"
        confirmButton.isHidden = true
        confirmButton.addAction(UIAction { [weak self] _ in self?.onConfirm?() }, for: .primaryActionTriggered)
        contentView.addSubview(confirmButton)
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
        measured = nil
        overlayWidth = -1
        page = nil
        highlights = []
        marks = []
        flashRange = nil
        speechToken = nil
        previewRange = nil
        confirmRange = nil
        confirmButton.isHidden = true
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
        // Let the text re-wrap to its final width first (a two-page column is narrower
        // than the list), so highlights are measured on the lines you actually see.
        textView.layoutIfNeeded()
        // Only when the width or the page changed: redrawing every highlight on every
        // layout pass slowed read-aloud down.
        if abs(textView.bounds.width - overlayWidth) > 0.5 { redrawOverlays() }
        layoutConfirm()
    }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if layoutAttributes.size != bounds.size { setNeedsLayout() }
    }

    /// Highlights, marks, the read-along tint, flash and pen preview, measured on the
    /// text as it's laid out now.
    private func redrawOverlays() {
        let width = textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right
        if width > 1, abs(textView.textContainer.size.width - width) > 0.5 {
            textView.textContainer.size = CGSize(width: width, height: textView.textContainer.size.height)
        }
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        overlayWidth = textView.bounds.width
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

    /// Shows the ✓ next to the circled word (a range of the page text), or hides it.
    func setConfirm(_ range: NSRange?) {
        confirmRange = range
        setNeedsLayout()
    }

    private func layoutConfirm() {
        guard let range = confirmRange, let r = rect(for: range) else {
            confirmButton.isHidden = true
            return
        }
        let e = textView.convert(r.circledWordEllipse, to: contentView)
        let size: CGFloat = 24
        var x = e.maxX + 6
        if x + size > contentView.bounds.maxX { x = e.minX - 6 - size }
        confirmButton.frame = CGRect(x: max(x, 0), y: e.midY - size / 2, width: size, height: size)
        confirmButton.isHidden = false
        contentView.bringSubviewToFront(confirmButton)
    }

    // MARK: Content

    func configure(page: LogicalPage, header text: String, highlights: [TextHighlight],
                   skipped: [NSRange], marks: [NSRange], fontSize: CGFloat, appearance: TextAppearance) {
        self.page = page
        measured = nil
        overlayWidth = -1
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
        measured = nil
        overlayWidth = -1
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
                switch h.style {
                case .underline:
                    shape.fillColor = h.color.withAlphaComponent(0.9).cgColor
                    shape.path = path(rects.map { r in
                        CGRect(x: r.minX, y: r.maxY - 2.5, width: r.width, height: 2.5)
                    }, radius: 1)
                case .circle:
                    // Highlighted as usual, plus a circle around it.
                    shape.fillColor = h.color.withAlphaComponent(0.42).cgColor
                    shape.path = path(rects, radius: 3)
                    let ring = CAShapeLayer()
                    ring.frame = highlightLayer.bounds
                    let p = UIBezierPath()
                    for r in rects { p.append(UIBezierPath(ovalIn: r.circledWordEllipse)) }
                    ring.path = p.cgPath
                    ring.fillColor = nil
                    ring.strokeColor = h.color.withAlphaComponent(0.9).cgColor
                    ring.lineWidth = 2
                    highlightLayer.addSublayer(ring)
                case .fill:
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
        let text = storage.string as NSString
        func isBlank(_ glyph: Int) -> Bool {
            let c = lm.characterIndexForGlyph(at: glyph)
            guard c < text.length, let u = UnicodeScalar(text.character(at: c)) else { return true }
            return CharacterSet.whitespacesAndNewlines.contains(u)
        }
        lm.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, container, lineGlyphs, _ in
            var r = NSIntersectionRange(lineGlyphs, glyphs)
            // Spaces and line breaks at either end aren't drawn: a paragraph break's box
            // runs to the end of the line (and past a two-page column).
            while r.length > 0, isBlank(NSMaxRange(r) - 1) { r.length -= 1 }
            while r.length > 0, isBlank(r.location) { r.location += 1; r.length -= 1 }
            guard r.length > 0 else { return }
            var box = lm.boundingRect(forGlyphRange: r, in: container)
            // Never wider than the column.
            box = box.intersection(CGRect(x: 0, y: box.minY, width: container.size.width, height: box.height))
            guard !box.isNull, box.width > 0 else { return }
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

    /// The words in an area (text view coordinates) with their boxes, for reading the
    /// shape of a highlighter stroke (circle / underline).
    func tokenRects(in area: CGRect) -> [(index: Int, rect: CGRect)] {
        guard let page, !page.tokenRanges.isEmpty else { return [] }
        let lm = textView.layoutManager
        guard lm.numberOfGlyphs > 0 else { return [] }
        let glyphs = lm.glyphRange(forBoundingRect: area, in: textView.textContainer)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard chars.length > 0, let lo = page.tokenIndex(atUTF16: chars.location),
              let hi = page.tokenIndex(atUTF16: NSMaxRange(chars) - 1), lo <= hi else { return [] }
        return (lo...hi).compactMap { i in
            let r = page.tokenRanges[i]
            guard r.length > 0, let rect = rect(for: r) else { return nil }
            return (index: i, rect: rect)
        }
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

/// The page's text view; tells the cell when its size really changes (the text then
/// wraps differently), so highlights can be measured again on the new lines.
final class ReportingTextView: UITextView {
    var onResize: (() -> Void)?
    private var lastSize: CGSize = .zero

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        onResize?()
    }
}
