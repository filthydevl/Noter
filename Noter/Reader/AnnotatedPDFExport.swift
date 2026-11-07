import UIKit
import PDFKit
import PencilKit

/// "Save PDF": a copy of the PDF with your highlights in it as real PDF highlight
/// annotations, so they show up in Files, Preview, Acrobat… Your note on a highlight
/// becomes its comment. Scribbles are left out unless you ask for them; then each
/// page is redrawn with your ink (and tidied text) baked onto it.
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
    static func export(info: DocumentInfo, highlights: [Highlight], ink: [Int: PageInkImage]?) -> URL? {
        let source = Storage.pdfURL(info.id)
        let document: PDFDocument?
        if let ink {
            document = flattened(source, ink: ink)
        } else {
            document = PDFDocument(url: source)
        }
        guard let document else { return nil }

        for h in highlights {
            guard let page = document.page(at: h.page) else { continue }
            let geometry = PageGeometry(page: page)
            for (i, r) in h.rects.enumerated() {
                let bounds = geometry.pageRect(fromNormalized: r.insetBy(dx: -0.002, dy: r.height * 0.04))
                let a = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                a.color = h.color.uiColor.withAlphaComponent(0.5)
                // Corners relative to the annotation: upper-left, upper-right, lower-left, lower-right.
                a.quadrilateralPoints = [
                    CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height),
                    CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0),
                ].map { NSValue(cgPoint: $0) }
                a.userName = "Noter"
                if i == 0, let note = h.noteText { a.contents = note }
                page.addAnnotation(a)
            }
        }

        let url = Storage.exportURL(for: info, ink == nil ? "Highlighted" : "Highlighted with scribbles", ext: "pdf")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        return document.write(to: url) ? url : nil
    }

    /// Redraws every page as displayed (text stays vector) with its scribbles on top.
    private static func flattened(_ source: URL, ink: [Int: PageInkImage]) -> PDFDocument? {
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
