import UIKit

/// Builds citations from a PDF's saved details and the page number printed on the
/// page a highlight is on. Plain rules, no AI: what comes out is exactly what you
/// typed in, arranged the way the style asks.
enum Citation {
    /// A run of text; `italic` for titles of books and journals.
    struct Piece {
        var text: String
        var italic = false
    }

    static func make(_ s: SourceInfo, page: String?, style: CitationStyle, quote: String?) -> [Piece] {
        var out: [Piece] = []
        if let quote {
            let clean = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Piece(text: "“\(clean)”\n\n"))
        }
        switch style {
        case .chicago:
            out += chicagoNote(s, page: page)
        case .mla:
            out.append(Piece(text: mlaInText(s, page: page) + "\n\n"))
            out += mlaEntry(s)
        }
        return out
    }

    // MARK: Chicago (notes and bibliography): the footnote

    /// First Last, *Title* (Place: Publisher, Year), 24.
    /// First Last, “Chapter,” in *Book*, ed. First Last (Place: Publisher, Year), 446.
    /// First Last, “Article,” *Journal* 17, no. 2 (2012): 152.
    static func chicagoNote(_ s: SourceInfo, page: String?) -> [Piece] {
        var p: [Piece] = []
        let authors = names(s.authors)
        if !authors.isEmpty { p.append(Piece(text: listed(authors, etAlFrom: 4) + ", ")) }
        let pageText = page.map(t) ?? ""
        switch s.kind {
        case .book:
            p.append(Piece(text: t(s.title), italic: true))
            if !t(s.edition).isEmpty { p.append(Piece(text: ", \(t(s.edition)) ed.")) }
            p.append(Piece(text: " (\(imprint(s)))"))
            if !pageText.isEmpty { p.append(Piece(text: ", \(pageText)")) }
        case .chapter:
            p.append(Piece(text: "“\(t(s.title)),” in "))
            p.append(Piece(text: t(s.container), italic: true))
            let editors = names(s.editors)
            if !editors.isEmpty { p.append(Piece(text: ", ed. \(listed(editors, etAlFrom: 4))")) }
            p.append(Piece(text: " (\(imprint(s)))"))
            if !pageText.isEmpty { p.append(Piece(text: ", \(pageText)")) }
        case .article:
            p.append(Piece(text: "“\(t(s.title)),” "))
            p.append(Piece(text: t(s.container), italic: true))
            if !t(s.volume).isEmpty { p.append(Piece(text: " \(t(s.volume))")) }
            if !t(s.issue).isEmpty { p.append(Piece(text: ", no. \(t(s.issue))")) }
            if !t(s.year).isEmpty { p.append(Piece(text: " (\(t(s.year)))")) }
            if !pageText.isEmpty { p.append(Piece(text: ": \(pageText)")) }
        }
        if !t(s.doi).isEmpty { p.append(Piece(text: ", \(doiLink(s.doi))")) }
        p.append(Piece(text: "."))
        return p
    }

    /// "Place: Publisher, Year", leaving out what isn't known.
    private static func imprint(_ s: SourceInfo) -> String {
        let house = [t(s.place), t(s.publisher)].filter { !$0.isEmpty }.joined(separator: ": ")
        return [house, t(s.year)].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: MLA (9th): in-text citation and works-cited entry

    /// (Davis 446)
    static func mlaInText(_ s: SourceInfo, page: String?) -> String {
        let last = names(s.authors).map(\.last)
        let who: String
        switch last.count {
        case 0: who = shortTitle(s.title)
        case 1: who = last[0]
        case 2: who = "\(last[0]) and \(last[1])"
        default: who = "\(last[0]) et al."
        }
        return "(" + [who, page.map(t) ?? ""].filter { !$0.isEmpty }.joined(separator: " ") + ")"
    }

    /// Last, First. *Title*. Publisher, Year.
    /// Last, First. “Chapter.” *Book*, edited by First Last, Publisher, Year, pp. 440–60.
    /// Last, First. “Article.” *Journal*, vol. 17, no. 2, 2012, pp. 149–67.
    static func mlaEntry(_ s: SourceInfo) -> [Piece] {
        var p: [Piece] = []
        let authors = names(s.authors)
        if let first = authors.first {
            var who = first.first.isEmpty ? first.last : "\(first.last), \(first.first)"
            if authors.count == 2 {
                who += ", and \(authors[1].full)"
            } else if authors.count > 2 {
                who += ", et al"
            }
            p.append(Piece(text: who + (who.hasSuffix(".") ? " " : ". ")))
        }
        var tail: [String] = []
        switch s.kind {
        case .book:
            p.append(Piece(text: t(s.title), italic: true))
            p.append(Piece(text: ". "))
            if !t(s.edition).isEmpty { tail.append("\(t(s.edition)) ed.") }
            tail += [t(s.publisher), t(s.year)]
        case .chapter:
            p.append(Piece(text: "“\(t(s.title)).” "))
            p.append(Piece(text: t(s.container), italic: true))
            p.append(Piece(text: ", "))
            let editors = names(s.editors)
            if !editors.isEmpty { tail.append("edited by \(listed(editors, etAlFrom: 3))") }
            tail += [t(s.publisher), t(s.year)]
            if !t(s.pages).isEmpty { tail.append("pp. \(t(s.pages))") }
        case .article:
            p.append(Piece(text: "“\(t(s.title)).” "))
            p.append(Piece(text: t(s.container), italic: true))
            p.append(Piece(text: ", "))
            if !t(s.volume).isEmpty { tail.append("vol. \(t(s.volume))") }
            if !t(s.issue).isEmpty { tail.append("no. \(t(s.issue))") }
            tail.append(t(s.year))
            if !t(s.pages).isEmpty { tail.append("pp. \(t(s.pages))") }
        }
        if !t(s.doi).isEmpty { tail.append(doiLink(s.doi)) }
        p.append(Piece(text: tail.filter { !$0.isEmpty }.joined(separator: ", ") + "."))
        return p
    }

    // MARK: Names

    struct Name {
        var first: String
        var last: String
        var full: String { first.isEmpty ? last : "\(first) \(last)" }
    }

    /// "John A. Davis; Anna Maria Rao" (or "Davis, John A.") → names. The last word is
    /// the family name, with its particle ("de Francesco", "van Gogh").
    static func names(_ field: String) -> [Name] {
        field.components(separatedBy: CharacterSet(charactersIn: ";\n"))
            .flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { raw -> Name in
                if let comma = raw.firstIndex(of: ",") {
                    return Name(first: raw[raw.index(after: comma)...].trimmingCharacters(in: .whitespaces),
                                last: raw[..<comma].trimmingCharacters(in: .whitespaces))
                }
                var words = raw.split(separator: " ").map(String.init)
                guard words.count > 1 else { return Name(first: "", last: raw) }
                var last = [words.removeLast()]
                let particles: Set<String> = ["de", "del", "della", "di", "da", "van", "von", "der", "den", "la", "le", "du"]
                while let w = words.last, words.count > 1, particles.contains(w.lowercased()) {
                    last.insert(words.removeLast(), at: 0)
                }
                return Name(first: words.joined(separator: " "), last: last.joined(separator: " "))
            }
    }

    /// "A", "A and B", "A, B, and C", or "A et al." from `etAlFrom` names up.
    private static func listed(_ names: [Name], etAlFrom: Int) -> String {
        let full = names.map(\.full)
        if full.count >= etAlFrom { return "\(full[0]) et al." }
        switch full.count {
        case 0: return ""
        case 1: return full[0]
        case 2: return "\(full[0]) and \(full[1])"
        default: return full.dropLast().joined(separator: ", ") + ", and " + full[full.count - 1]
        }
    }

    private static func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func shortTitle(_ title: String) -> String {
        t(title).split(separator: " ").prefix(4).joined(separator: " ")
    }

    private static func doiLink(_ doi: String) -> String {
        let d = t(doi)
        return d.lowercased().hasPrefix("http") ? d : "https://doi.org/\(d)"
    }

    // MARK: Clipboard

    static func plain(_ pieces: [Piece]) -> String { pieces.map(\.text).joined() }

    /// Formatted (titles in italics) for apps that take it, plain text for the rest.
    static func copy(_ pieces: [Piece]) {
        let rich = NSMutableAttributedString()
        let size: CGFloat = 12
        let regular = UIFont(name: "TimesNewRomanPSMT", size: size) ?? .systemFont(ofSize: size)
        let italic = UIFont(name: "TimesNewRomanPS-ItalicMT", size: size) ?? .italicSystemFont(ofSize: size)
        for p in pieces {
            rich.append(NSAttributedString(string: p.text, attributes: [.font: p.italic ? italic : regular]))
        }
        var item: [String: Any] = ["public.utf8-plain-text": plain(pieces)]
        if let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            item["public.rtf"] = rtf
        }
        UIPasteboard.general.setItems([item])
    }
}
