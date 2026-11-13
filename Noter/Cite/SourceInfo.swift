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

    /// Saved details, else a start from what the PDF says about itself (its title and
    /// author fields, and a DOI printed on the first pages).
    @MainActor
    static func load(for session: DocumentSession) -> SourceInfo {
        if let saved = Storage.load(SourceInfo.self, from: url(session.info.id)) { return saved }
        var s = SourceInfo()
        let attributes = session.pdf.documentAttributes ?? [:]
        if let t = attributes[PDFDocumentAttribute.titleAttribute] as? String { s.title = t.trimmingCharacters(in: .whitespaces) }
        if let a = attributes[PDFDocumentAttribute.authorAttribute] as? String { s.authors = a.trimmingCharacters(in: .whitespaces) }
        if s.title.isEmpty { s.title = session.info.title }
        for i in 0..<min(session.pdf.pageCount, 3) {
            guard let text = session.pdf.page(at: i)?.string,
                  let r = text.range(of: #"10\.\d{4,9}/[^\s"<>]+"#, options: .regularExpression) else { continue }
            s.doi = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
            break
        }
        return s
    }
}
