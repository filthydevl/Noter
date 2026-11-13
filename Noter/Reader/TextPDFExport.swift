import UIKit
import PDFKit
import PencilKit

/// "Save Text view": the recognized text as a PDF — your reading font, headings,
/// highlights — with your scribbles beside the same words they sit by on the pages.
@MainActor
enum TextPDFExport {
    static let paper = CGSize(width: 612, height: 792) // US Letter, in points
    static let margin: CGFloat = 60

    static func export(_ session: DocumentSession) async -> URL? {
        session.pdfController?.saveAllInk()
        let url = Storage.exportURL(for: session.info, "Text with scribbles", ext: "pdf")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var appearance = session.textAppearance
        appearance.theme = .light // paper is white
        let size: CGFloat = 12
        let column = CGSize(width: paper.width - margin * 2, height: paper.height - margin * 2)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: paper))
        var wrote = false

        // Pages are laid out a few at a time so the app stays responsive.
        var prepared: [Prepared] = []
        for index in 0..<session.pageCount {
            guard let pages = session.logicalPages(index), let pdfPage = session.pdf.page(at: index) else { continue }
            let pageSize = TextInk.pageSize(pdfPage)
            let ink = InkStore.load(session.info.id, page: index)
            let strokes = ink.drawing.flatMap { try? PKDrawing(data: $0) }?.strokes ?? []
            for lp in pages where !lp.text.isEmpty {
                prepared.append(prepare(lp, session: session, appearance: appearance, size: size, width: column.width,
                                        strokes: strokes.filter { TextInk.belongs($0, to: lp, pageSize: pageSize) },
                                        pageSize: pageSize))
            }
            if index % 8 == 7 { await Task.yield() }
        }
        guard !prepared.isEmpty else { return nil }

        do {
            try renderer.writePDF(to: url) { context in
                for item in prepared {
                    for slice in item.slices(height: column.height) {
                        context.beginPage()
                        wrote = true
                        let cg = context.cgContext
                        cg.saveGState()
                        cg.translateBy(x: margin, y: margin - slice.minY)
                        let glyphs = item.layout.glyphRange(forBoundingRect: slice, in: item.container)
                        item.layout.drawBackground(forGlyphRange: glyphs, at: .zero)
                        item.layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
                        cg.restoreGState()
                        // The scribbles over this stretch of text, margins included.
                        if !item.ink.strokes.isEmpty {
                            let area = CGRect(x: -margin, y: slice.minY - 8, width: paper.width, height: slice.height + 16)
                            var image: UIImage?
                            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                                image = item.ink.image(from: area, scale: 3)
                            }
                            image?.draw(in: CGRect(x: 0, y: margin - 8, width: area.width, height: area.height))
                        }
                    }
                }
            }
        } catch {
            return nil
        }
        return wrote ? url : nil
    }

    /// One book page laid out in a column of its own, with its ink placed on it.
    private struct Prepared {
        let storage: NSTextStorage
        let layout: NSLayoutManager
        let container: NSTextContainer
        let ink: PKDrawing

        /// Stretches of the column that each fit a sheet, cut between lines.
        func slices(height: CGFloat) -> [CGRect] {
            var out: [CGRect] = []
            var start: CGFloat = 0
            var end: CGFloat = 0
            let all = layout.glyphRange(for: container)
            layout.enumerateLineFragments(forGlyphRange: all) { rect, _, _, _, _ in
                if rect.maxY - start > height, end > start {
                    out.append(CGRect(x: 0, y: start, width: container.size.width, height: end - start))
                    start = end
                }
                end = rect.maxY
            }
            if end > start { out.append(CGRect(x: 0, y: start, width: container.size.width, height: end - start)) }
            return out
        }
    }

    private static func prepare(_ lp: LogicalPage, session: DocumentSession, appearance: TextAppearance,
                                size: CGFloat, width: CGFloat, strokes: [PKStroke], pageSize: CGSize) -> Prepared {
        // "p. 24" above the page's text.
        let label = NSAttributedString(
            string: session.label(for: lp.slot) + "\n\n",
            attributes: [.font: UIFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: UIColor.gray])
        let body = NSMutableAttributedString(string: lp.text, attributes: appearance.bodyAttributes(size: size))
        let heading = appearance.headingAttributes(size: size)
        for r in lp.headingRanges where NSMaxRange(r) <= body.length { body.addAttributes(heading, range: r) }
        let note = appearance.footnoteAttributes(size: size)
        for r in lp.footnoteRanges where NSMaxRange(r) <= body.length { body.addAttributes(note, range: r) }
        for h in session.transcriptHighlightRanges(lp) where NSMaxRange(h.range) <= body.length {
            if h.style == .fill {
                body.addAttribute(.backgroundColor, value: h.color.withAlphaComponent(0.35), range: h.range)
            } else {
                body.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: h.range)
                body.addAttribute(.underlineColor, value: h.color, range: h.range)
            }
        }
        let text = NSMutableAttributedString(attributedString: label)
        let offset = text.length
        text.append(body)

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)

        let placed = TextInk.toText(strokes, lp: lp, pageSize: pageSize) { token in
            guard token < lp.tokenRanges.count, lp.tokenRanges[token].length > 0 else { return nil }
            let r = lp.tokenRanges[token]
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: r.location + offset, length: r.length),
                                           actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            return rect.width > 0 ? rect : nil
        }
        return Prepared(storage: storage, layout: layout, container: container,
                        ink: PKDrawing(strokes: placed.map(\.shown)))
    }
}
