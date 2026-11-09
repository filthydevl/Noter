import UIKit
import PDFKit
import PencilKit

/// "Save PDF": a copy of the PDF with your work in it.
/// * Baked (the default): every page is redrawn with your highlights, definition
///   underlines and scribbles (ink and tidied text) printed onto it — they look the same
///   everywhere and can't be lost or edited by accident. Text stays sharp and searchable.
/// * Editable: the original pages with the highlights as real PDF highlight / underline
///   annotations other apps can change; scribbles left out.
/// Either way, a highlight's note is added as a PDF sticky note next to it.
enum AnnotatedPDFExport {
    /// A page's scribbles, ready to draw (prepared on the main thread).
    struct PageInkImage {
        let image: UIImage?
        let texts: [InkText]
    }

    /// Main thread: the latest ink of every page that has any, as images.
    @MainActor
    static func inkImages(_ session: DocumentSession) -> [Int: PageInkImage] {
        session.pdfController?.saveAllInk()
        let id = session.info.id
        let files = (try? FileManager.default.contentsOfDirectory(atPath: InkStore.folder(id).path)) ?? []
        var out: [Int: PageInkImage] = [:]
        for name in files where name.hasPrefix("p") && name.hasSuffix(".json") {
            guard let index = Int(name.dropFirst().dropLast(5)), let page = session.pdf.page(at: index) else { continue }
            let ink = InkStore.load(id, page: index)
            let size = displayedSize(page)
            var image: UIImage?
            if let data = ink.drawing, let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty {
                // Light appearance, so black ink stays black whatever mode the iPad is in.
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    image = drawing.image(from: CGRect(origin: .zero, size: size), scale: 3)
                }
            }
            if image != nil || !ink.texts.isEmpty { out[index] = PageInkImage(image: image, texts: ink.texts) }
        }
        return out
    }

    /// Any thread. Returns the saved file (in Documents/Highlights) or nil.
    /// `ink` given: baked. Nil: editable highlights, no scribbles.
    static func export(info: DocumentInfo, highlights: [Highlight], ink: [Int: PageInkImage]?) -> URL? {
        let source = Storage.pdfURL(info.id)
        let document: PDFDocument?
        if let ink {
            document = flattened(source, ink: ink, highlights: Dictionary(grouping: highlights, by: \.page))
        } else {
            document = PDFDocument(url: source)
        }
        guard let document else { return nil }

        for h in highlights {
            guard let page = document.page(at: h.page) else { continue }
            let geometry = PageGeometry(page: page)
            if ink == nil {
                for r in h.rects {
                    if h.style == .circle {
                        // A circled word: a circle annotation around its highlight.
                        let bounds = geometry.pageRect(fromNormalized: r.circledWordEllipse)
                        let a = PDFAnnotation(bounds: bounds, forType: .circle, withProperties: nil)
                        a.color = h.uiColor
                        let border = PDFBorder()
                        border.lineWidth = max(bounds.height * 0.05, 1)
                        a.border = border
                        a.userName = "Noter"
                        page.addAnnotation(a)
                    }
                    let bounds = geometry.pageRect(fromNormalized: r.insetBy(dx: -0.002, dy: r.height * 0.04))
                    let a = PDFAnnotation(bounds: bounds, forType: h.isUnderlined ? .underline : .highlight,
                                          withProperties: nil)
                    a.color = h.uiColor.withAlphaComponent(h.isUnderlined ? 1 : 0.5)
                    // Corners relative to the annotation: upper-left, upper-right, lower-left, lower-right.
                    a.quadrilateralPoints = [
                        CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height),
                        CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0),
                    ].map { NSValue(cgPoint: $0) }
                    a.userName = "Noter"
                    page.addAnnotation(a)
                }
            }
            // The note as a sticky note at the end of the highlight's first line.
            if let note = h.noteText, let first = h.rects.first {
                let b = geometry.pageRect(fromNormalized: first)
                let a = PDFAnnotation(bounds: CGRect(x: b.maxX + 2, y: b.maxY - 14, width: 16, height: 16),
                                      forType: .text, withProperties: nil)
                a.contents = note
                a.color = h.uiColor
                a.userName = "Noter"
                page.addAnnotation(a)
            }
        }

        let url = Storage.exportURL(for: info, ink == nil ? "Highlighted" : "Highlighted with scribbles", ext: "pdf")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        return document.write(to: url) ? url : nil
    }

    /// Redraws every page as displayed (text stays vector) with its highlights and
    /// scribbles printed on.
    private static func flattened(_ source: URL, ink: [Int: PageInkImage],
                                  highlights: [Int: [Highlight]]) -> PDFDocument? {
        guard let pdf = CGPDFDocument(source as CFURL), pdf.numberOfPages > 0 else { return nil }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { ctx in
            for index in 0..<pdf.numberOfPages {
                guard let page = pdf.page(at: index + 1) else { continue }
                let box = page.getBoxRect(.cropBox)
                let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
                let size = rotation == 90 || rotation == 270
                    ? CGSize(width: box.height, height: box.width) : box.size
                let rect = CGRect(origin: .zero, size: size)
                ctx.beginPage(withBounds: rect, pageInfo: [:])
                let c = ctx.cgContext
                c.saveGState()
                c.translateBy(x: 0, y: size.height)
                c.scaleBy(x: 1, y: -1)
                c.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
                c.drawPDFPage(page)
                c.restoreGState()

                // Highlights, multiplied onto the page like a real highlighter; a circled
                // word as a circle around it, its definition as an underline.
                for h in highlights[index] ?? [] {
                    for n in h.rects {
                        var r = CGRect(x: n.minX * size.width, y: n.minY * size.height,
                                       width: n.width * size.width, height: n.height * size.height)
                            .insetBy(dx: -size.width * 0.002, dy: n.height * size.height * 0.04)
                        c.saveGState()
                        if h.style == .circle {
                            // The circle around a circled word; its highlight is filled next.
                            let e = r.circledWordEllipse
                            c.setStrokeColor(h.uiColor.cgColor)
                            c.setLineWidth(max(e.height * 0.05, 1))
                            c.strokeEllipse(in: e)
                        }
                        if h.isUnderlined {
                            let bar = max(r.height * 0.12, 1)
                            r = CGRect(x: r.minX, y: r.maxY - bar, width: r.width, height: bar)
                            c.setFillColor(h.uiColor.cgColor)
                        } else {
                            c.setBlendMode(.multiply)
                            c.setFillColor(h.uiColor.withAlphaComponent(0.5).cgColor)
                        }
                        c.addPath(UIBezierPath(roundedRect: r, cornerRadius: min(r.height * 0.2, 2)).cgPath)
                        c.fillPath()
                        c.restoreGState()
                    }
                }

                guard let pageInk = ink[index] else { continue }
                pageInk.image?.draw(in: rect)
                for t in pageInk.texts {
                    let frame = CGRect(x: t.rect.minX * size.width, y: t.rect.minY * size.height,
                                       width: t.rect.width * size.width, height: t.rect.height * size.height)
                    let lineHeight = frame.height / CGFloat(max(t.lines, 1))
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: t.style.font(size: max(lineHeight * 0.72, 4)),
                        .foregroundColor: UIColor(hex: t.colorHex) ?? .black,
                    ]
                    NSAttributedString(string: t.text, attributes: attributes)
                        .draw(with: frame, options: [.usesLineFragmentOrigin], context: nil)
                }
            }
        }
        return PDFDocument(data: data)
    }

    private static func displayedSize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        return rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }
}
