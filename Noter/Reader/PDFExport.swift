import UIKit
import SwiftUI

/// Builds the PDF exports (highlights, key words, questions) as styled HTML and prints
/// it to PDF with UIKit's print renderer. Files go to `Documents/Highlights/` so they
/// also show up in the Files app.
@MainActor
enum PDFExport {
    /// Highlights with their tags and notes (`onlyWithNotes`: the Notes panel's export).
    static func highlights(_ session: DocumentSession, onlyWithNotes: Bool = false) -> URL? {
        let items = session.sortedHighlights().filter { !onlyWithNotes || $0.noteText != nil }
        let keywords = Dictionary(uniqueKeysWithValues: session.keywordEntries().map { ($0.id, $0) })
        var body = ""
        var lastLabel: String?
        for h in items {
            let label = session.pageLabel(for: h)
            if label != lastLabel {
                body += "<h2>\(esc(label))</h2>"
                lastLabel = label
            }
            body += "<div class='quote' style='border-left-color:\(h.color.hex)'>\(esc(h.text))"
            let tags = h.tagKeys.compactMap { keywords[$0] }
            if !tags.isEmpty {
                body += "<div class='tags'>" + tags.map(tag).joined(separator: " ") + "</div>"
            }
            if let note = h.noteText {
                body += "<div class='note'>" + esc(note).replacingOccurrences(of: "\n", with: "<br>") + "</div>"
            }
            body += "</div>"
        }
        if onlyWithNotes {
            let count = "\(items.count) note\(items.count == 1 ? "" : "s")"
            return write(session, "Notes", title: "Notes", subtitle: count, body: body)
        }
        let count = "\(items.count) highlight\(items.count == 1 ? "" : "s")"
        return write(session, "Highlights", title: "Highlights", subtitle: count, body: body)
    }

    static func keywords(_ session: DocumentSession) -> URL? {
        let entries = session.keywordEntries()
        var body = ""
        for k in entries {
            let pages = unique(k.mentions.map { session.pageLabel(for: $0) }).joined(separator: ", ")
            body += "<div class='keyword'><span class='tag big' style='background:\(k.color.hex)55;"
                + "border-color:\(k.color.hex)'>\(esc(k.text))</span>"
                + "<span class='meta'>Highlighted on \(esc(pages))</span>"
            if k.linked.isEmpty {
                body += "<div class='none'>No highlights tagged yet.</div>"
            } else {
                for h in k.linked {
                    body += "<div class='quote' style='border-left-color:\(h.color.hex)'>\(esc(h.text))"
                        + "<div class='meta'>\(esc(session.pageLabel(for: h)))</div></div>"
                }
            }
            body += "</div>"
        }
        let count = "\(entries.count) key word\(entries.count == 1 ? "" : "s")"
        return write(session, "Key words", title: "Key words", subtitle: count, body: body)
    }

    static func questions(_ session: DocumentSession, _ list: [Question]) -> URL? {
        var body = ""
        var lastLabel: String?
        for q in list {
            let label = session.label(for: q.location.slot)
            if label != lastLabel {
                body += "<h2>\(esc(label))</h2>"
                lastLabel = label
            }
            body += "<div class='quote' style='border-left-color:#AF52DE'>\(esc(q.text))"
                + "<div class='meta'>\(q.kind.title)</div></div>"
        }
        let count = "\(list.count) question\(list.count == 1 ? "" : "s")"
        return write(session, "Questions", title: "Questions", subtitle: count, body: body)
    }

    // MARK: Rendering

    private static func tag(_ k: KeywordEntry) -> String {
        "<span class='tag' style='background:\(k.color.hex)55;border-color:\(k.color.hex)'>\(esc(k.text))</span>"
    }

    private static func write(_ session: DocumentSession, _ kind: String, title: String, subtitle: String,
                              body: String) -> URL? {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let html = """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica, sans-serif; color: #1c1c1e; font-size: 12pt; }
        h1 { font-size: 22pt; margin: 0 0 2pt 0; }
        .sub { color: #8e8e93; font-size: 10pt; margin-bottom: 14pt; }
        h2 { font-size: 11pt; color: #6e6e73; margin: 16pt 0 6pt 0; text-transform: uppercase; }
        .quote { font-family: 'New York', Georgia, serif; border-left: 4pt solid #ccc; padding: 2pt 0 2pt 9pt;
                 margin: 0 0 9pt 0; line-height: 1.4; }
        .meta { font-family: -apple-system, Helvetica, sans-serif; color: #8e8e93; font-size: 9pt; margin-top: 3pt; }
        .tags { margin-top: 4pt; }
        .note { font-family: -apple-system, Helvetica, sans-serif; font-size: 10.5pt; color: #3a3a3c;
                background: #f2f2f7; border-radius: 6pt; padding: 5pt 8pt; margin-top: 6pt; line-height: 1.35; }
        .tag { font-family: -apple-system, Helvetica, sans-serif; font-size: 9pt; font-weight: 600;
               border: 1pt solid; border-radius: 6pt; padding: 1pt 6pt; }
        .tag.big { font-size: 13pt; padding: 2pt 8pt; }
        .keyword { margin: 0 0 16pt 0; }
        .keyword .meta { margin-left: 8pt; }
        .keyword .quote { margin-top: 8pt; }
        .none { color: #8e8e93; font-size: 10pt; margin-top: 6pt; }
        </style></head><body>
        <h1>\(esc(session.info.title)) — \(esc(title))</h1>
        <div class='sub'>\(esc(subtitle)) · exported \(esc(formatter.string(from: Date())))</div>
        \(body)
        </body></html>
        """
        let url = Storage.exportURL(for: session.info, kind, ext: "pdf")
        do {
            try render(html).write(to: url, options: [.atomic])
            return url
        } catch {
            print("Noter: failed to export \(kind) PDF: \(error)")
            return nil
        }
    }

    /// US Letter, half-inch-ish margins.
    private static func render(_ html: String) -> Data {
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper.insetBy(dx: 48, dy: 54)), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, [kCGPDFContextTitle as String: "Noter export"])
        for page in 0..<max(renderer.numberOfPages, 1) {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

/// A file to hand to the share sheet.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIKit's share sheet (Save to Files, AirDrop, Mail…).
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
