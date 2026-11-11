import Foundation

/// Writes `Documents/Highlights/<title> – Highlights.md` — only the text of your
/// highlights, grouped by the page number printed in the book. Rewritten on every
/// change; it shows up in the Files app under "On My iPad › Noter".
enum HighlightExporter {
    @MainActor
    static func export(_ session: DocumentSession) {
        let items = session.groupedHighlights()
        let url = Storage.exportURL(for: session.info)
        if items.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var md = "# \(session.info.title) — Highlights\n\n"
        md += "_\(items.count) highlight\(items.count == 1 ? "" : "s") · updated \(formatter.string(from: Date()))_\n"
        let keywords = session.tagEntriesByKey().mapValues(\.text)
        var lastLabel: String?
        for h in items {
            let label = session.pageLabel(for: h)
            if label != lastLabel {
                md += "\n## \(label)\n\n"
                lastLabel = label
            }
            if let word = session.term(of: h) {
                md += "↓ _Definition of “\(Highlight.keywordDisplay(word.text))”_\n\n"
            } else if h.isTerm {
                md += "**Word:** \(Highlight.keywordDisplay(h.text))\n\n"
            } else if let name = session.palette.name(h.color) {
                md += "_\(name)_\n\n"
            }
            let quoted = h.text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { "> \($0)" }
                .joined(separator: "\n>\n")
            md += quoted + "\n"
            let tags = session.tagKeys(of: h).compactMap { keywords[$0] }
            if !tags.isEmpty { md += "\nKey words: " + tags.map { "`\($0)`" }.joined(separator: " ") + "\n" }
            if let note = h.noteText {
                md += "\n**Note:** " + note.replacingOccurrences(of: "\n", with: "  \n") + "\n"
            }
            md += "\n"
        }
        try? Data(md.utf8).write(to: url, options: [.atomic])
    }

    @MainActor
    static func plainText(_ session: DocumentSession) -> String {
        session.sortedHighlights()
            .map { h in
                var s = "\(h.text)\n— \(session.pageLabel(for: h))"
                if let note = h.noteText { s += "\nNote: \(note)" }
                return s
            }
            .joined(separator: "\n\n")
    }
}
