import Foundation
import PDFKit

/// Where the reader is in the PDF / Text view: the word at the top of the screen.
@MainActor
final class ReaderPosition: ObservableObject {
    @Published var anchor: TextAnchor?
    /// A word you just touched, highlighted or wrote beside (`count` makes touching the
    /// same word twice count twice).
    @Published var touched: Touched?

    struct Touched: Equatable {
        var anchor: TextAnchor
        var count: Int
    }
}

enum CitationStyle: String, CaseIterable, Identifiable {
    case chicago, mla
    var id: String { rawValue }
    var title: String { self == .chicago ? "Chicago" : "MLA" }
}

/// What a citation needs to know about the book (or chapter, or article) a PDF is.
/// You fill it in once per PDF; the page number comes from the page itself.
struct SourceInfo: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case book, chapter, article
        var id: String { rawValue }
        var title: String {
            switch self {
            case .book: "Book"
            case .chapter: "Chapter in a book"
            case .article: "Journal article"
            }
        }
    }

    var kind: Kind = .book
    /// "First Last", several separated by ";".
    var authors = ""
    /// The book's title — or the chapter's / article's.
    var title = ""
    /// Chapter: the book it's in. Article: the journal.
    var container = ""
    /// Chapter: the book's editors ("First Last; First Last").
    var editors = ""
    var publisher = ""
    var place = ""
    var year = ""
    var edition = ""
    var volume = ""
    var issue = ""
    /// Chapter / article: its page range ("440–460").
    var pages = ""
    var doi = ""

    var isUsable: Bool {
        !authors.trimmingCharacters(in: .whitespaces).isEmpty && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func url(_ id: UUID) -> URL { Storage.folder(id).appendingPathComponent("source.json") }

    /// Where the details came from: "crossref" (looked up by DOI), "guess" (read off
    /// the pages), nil once you've saved them yourself.
    var origin: String?

    /// Saved details, else what can be read off the PDF itself: its title and author
    /// (from the pages' running headers and first heading, or the PDF's own fields — a
    /// file name is tidied, never used raw), the publisher line and a DOI.
    @MainActor
    static func load(for session: DocumentSession) -> SourceInfo {
        if let saved = Storage.load(SourceInfo.self, from: url(session.info.id)) { return saved }
        return guess(for: session)
    }

    @MainActor
    static func guess(for session: DocumentSession) -> SourceInfo {
        var s = SourceInfo()
        s.origin = "guess"
        let attributes = session.pdf.documentAttributes ?? [:]
        let pdfTitle = (attributes[PDFDocumentAttribute.titleAttribute] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let pdfAuthor = (attributes[PDFDocumentAttribute.authorAttribute] as? String ?? "").trimmingCharacters(in: .whitespaces)

        // The first pages' own text layer: DOI, publisher.
        var front = ""
        for i in 0..<min(session.pdf.pageCount, 3) { front += (session.pdf.page(at: i)?.string ?? "") + "\n" }
        if let r = front.range(of: #"10\.\d{4,9}/[^\s"<>]+"#, options: .regularExpression) {
            s.doi = String(front[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
        }
        if let r = front.range(of: #"(?<=Published (online )?by )[^\n]+"#, options: .regularExpression) {
            s.publisher = tidy(String(front[r]))
        } else if let r = front.range(of: #"[A-Z][A-Za-z]+( [A-Z][A-Za-z]+)* University Press"#, options: .regularExpression) {
            s.publisher = tidy(String(front[r]))
        }
        if let r = front.range(of: #"(?<=©\s?)(1[5-9]|20)\d{2}"#, options: .regularExpression) { s.year = String(front[r]) }

        // The recognized pages: the running headers usually alternate between the
        // author's name and the title; the first heading is the title otherwise.
        var headers: [String: Int] = [:]
        var firstHeading: String?
        for i in 0..<min(session.pdf.pageCount, 6) {
            for lp in session.logicalPages(i) ?? [] {
                if let h = lp.runningHeader.map(tidy), h.count >= 4 { headers[h, default: 0] += 1 }
                if firstHeading == nil, let r = lp.headingRanges.first, NSMaxRange(r) <= (lp.text as NSString).length {
                    firstHeading = tidy((lp.text as NSString).substring(with: r))
                }
            }
        }
        let ranked = headers.sorted { $0.value > $1.value }.map(\.key)
        let name = ranked.first(where: looksLikeName)
        let titleHeader = ranked.first { !looksLikeName($0) && $0.rangeOfCharacter(from: .decimalDigits) == nil }

        s.authors = !pdfAuthor.isEmpty ? pdfAuthor : (name.map(properName) ?? "")
        let fromFile = cleanedFileTitle(session.info.title)
        if !pdfTitle.isEmpty, !looksLikeFileName(pdfTitle) {
            s.title = pdfTitle
        } else {
            s.title = titleHeader ?? firstHeading ?? fromFile
        }
        return s
    }

    private static func tidy(_ t: String) -> String {
        t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,;:·–—-"))
    }

    /// "JOHN A. DAVIS", "Anna Maria Rao": a few capitalized words and initials.
    private static func looksLikeName(_ t: String) -> Bool {
        let words = t.split(separator: " ")
        guard (2...4).contains(words.count), t.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        let caps = t.filter(\.isLetter).allSatisfy(\.isUppercase)
        let shape = words.allSatisfy { w in
            w.first?.isUppercase == true && w.allSatisfy { $0.isLetter || $0 == "." || $0 == "-" || $0 == "'" }
        }
        return shape && (caps || words.contains { $0.count <= 2 && $0.hasSuffix(".") })
    }

    /// "JOHN A. DAVIS" → "John A. Davis".
    private static func properName(_ t: String) -> String {
        t.split(separator: " ").map { w in
            w.count <= 2 ? String(w) : String(w.prefix(1)).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    static func looksLikeFileName(_ t: String) -> Bool {
        t.contains("_") || t.contains("+") || t.lowercased().hasSuffix(".pdf") || !t.contains(" ")
    }

    /// "17+italy_revolution_and_counterrevolution_17891799" → "Italy Revolution and
    /// Counterrevolution 1789–1799": no file-name punctuation, no leading number.
    static func cleanedFileTitle(_ raw: String) -> String {
        var t = raw
        if t.lowercased().hasSuffix(".pdf") { t = String(t.dropLast(4)) }
        t = t.replacingOccurrences(of: #"^\d+\s*[+_.\-]\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[_+]+"#, with: " ", options: .regularExpression)
        // "17891799" → "1789–1799"
        t = t.replacingOccurrences(of: #"\b((?:1[5-9]|20)\d{2})((?:1[5-9]|20)\d{2})\b"#, with: "$1–$2",
                                   options: .regularExpression)
        let small: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to"]
        let words = tidy(t).split(separator: " ").enumerated().map { i, w -> String in
            let lower = w.lowercased()
            if i > 0, small.contains(lower) { return lower }
            return w == w.lowercased() ? String(w.prefix(1)).uppercased() + w.dropFirst() : String(w)
        }
        return words.joined(separator: " ")
    }

    /// The publisher's own record for a DOI, from Crossref (the registry publishers
    /// file their books and articles with): exact title, authors, year, pages. Only the
    /// DOI is sent. Nil when there's no record or no connection.
    static func lookUp(doi raw: String) async -> SourceInfo? {
        var doi = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://doi.org/", "http://doi.org/", "doi:"] where doi.lowercased().hasPrefix(prefix) {
            doi = String(doi.dropFirst(prefix.count))
        }
        guard !doi.isEmpty,
              let path = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.crossref.org/works/\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Noter", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let m = json["message"] as? [String: Any] else { return nil }

        func text(_ value: Any?) -> String {
            let raw = (value as? [String])?.first ?? (value as? String) ?? ""
            return raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        func people(_ value: Any?) -> String {
            ((value as? [[String: Any]]) ?? []).compactMap { p -> String? in
                let given = text(p["given"]), family = text(p["family"])
                let whole = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
                return whole.isEmpty ? (text(p["name"]).isEmpty ? nil : text(p["name"])) : whole
            }.joined(separator: "; ")
        }
        func year(_ key: String) -> String? {
            let parts = ((m[key] as? [String: Any])?["date-parts"] as? [[Any]])?.first
            return (parts?.first as? Int).map(String.init)
        }

        var s = SourceInfo()
        s.origin = "crossref"
        s.doi = doi
        switch text(m["type"]) {
        case "book-chapter", "book-section", "book-part", "reference-entry": s.kind = .chapter
        case "journal-article", "proceedings-article": s.kind = .article
        default: s.kind = .book
        }
        s.title = text(m["title"])
        let subtitle = text(m["subtitle"])
        if !subtitle.isEmpty, !s.title.localizedCaseInsensitiveContains(subtitle) { s.title += ": " + subtitle }
        s.authors = people(m["author"])
        s.editors = people(m["editor"])
        s.container = text(m["container-title"])
        s.publisher = text(m["publisher"])
        s.place = text(m["publisher-location"])
        s.year = year("published-print") ?? year("published") ?? year("issued") ?? year("published-online") ?? ""
        s.volume = text(m["volume"])
        s.issue = text(m["issue"])
        s.pages = text(m["page"]).replacingOccurrences(of: "-", with: "–")
        // A book with editors and no authors is cited by its editors.
        if s.kind == .book, s.authors.isEmpty { s.authors = s.editors }
        return s.title.isEmpty ? nil : s
    }
}
