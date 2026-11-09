import Foundation
import UIKit
import CoreGraphics

// MARK: - Library / document

enum LayoutMode: String, Codable, CaseIterable, Identifiable {
    /// Detect two-page book spreads automatically (landscape scans with a gutter).
    case auto
    /// Every PDF page is one book page.
    case single
    /// Every PDF page holds two book pages side by side.
    case spread

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto-detect"
        case .single: "Single pages"
        case .spread: "Two-page spreads"
        }
    }
}

enum ViewMode: String, Codable, CaseIterable, Identifiable {
    case pdf, transcript, highlights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: "PDF"
        case .transcript: "Text"
        case .highlights: "Highlights"
        }
    }
}

/// What the pencil does: draw with the current pen (the highlighter or the scribble
/// pen, see `PenMode`) or erase (highlights or ink, depending on the pen).
enum PencilTool: String {
    case pen, erase
}

/// The pen button toggles between highlighting text and scribbling freely.
enum PenMode: String {
    case highlight, scribble
}

struct DocumentInfo: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var pageCount: Int
    var added: Date
    var lastOpened: Date?
    var layoutMode: LayoutMode
    var lastPage: Int
    var viewMode: ViewMode
    var highlightCount: Int
    var ocrPagesDone: Int
}

// MARK: - OCR results (stored per PDF page)
// All rects are normalized to the *displayed* page (rotation applied),
// origin top-left, 0...1 on both axes.

struct OCRToken: Codable {
    var t: String
    var r: CGRect
}

struct OCRLine: Codable {
    var t: String
    var r: CGRect
    var k: [OCRToken]
}

struct OCRPage: Codable {
    var page: Int
    /// width / height of the displayed page
    var aspect: CGFloat
    var lines: [OCRLine]
    /// `OCREngine.version` that produced it (nil: before versions existed).
    var v: Int?
}

/// A printed page number found on a book page ("folio").
struct Folio: Codable, Hashable {
    var value: Int
    var roman: Bool
}

/// How one PDF page splits into book pages for a given layout mode.
struct PageSplit: Codable, Hashable {
    var gutter: CGFloat?
    /// One entry per book page on this PDF page (1 or 2).
    var folios: [Folio?]
}

/// Small per-page summary kept in an index so we never have to load
/// every page's OCR file to work out page numbers.
struct PageMeta: Codable {
    var auto: PageSplit
    var single: PageSplit
    var spread: PageSplit

    func split(_ mode: LayoutMode) -> PageSplit {
        switch mode {
        case .auto: auto
        case .single: single
        case .spread: spread
        }
    }
}

// MARK: - Positions

/// One book page: a PDF page index plus which half of a spread (0 = left / only).
struct SlotKey: Hashable, Codable {
    var pdfIndex: Int
    var half: Int
}

struct SpeechPosition: Equatable {
    var pdfIndex: Int
    var half: Int
    var token: Int

    var slot: SlotKey { SlotKey(pdfIndex: pdfIndex, half: half) }
}

/// A spot in the book: a word on a book page. Used to keep the PDF and Text views on the
/// same place when you switch between them.
struct TextAnchor: Equatable {
    var slot: SlotKey
    var token: Int
}

/// Identifies a single OCR word: raw OCR line index + token index within that line.
struct TokenKey: Codable, Hashable {
    var line: Int
    var token: Int
}

// MARK: - Highlights

/// A highlight color: one of the built-in ones ("yellow"…) or one you added from the
/// color wheel ("#RRGGBB"). Stored as that string, so older highlights still load.
struct HighlightColor: RawRepresentable, Codable, Hashable, Identifiable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    private init(_ raw: String) { rawValue = raw }

    static let yellow = HighlightColor("yellow")
    static let green = HighlightColor("green")
    static let blue = HighlightColor("blue")
    static let pink = HighlightColor("pink")
    static let orange = HighlightColor("orange")
    /// Circled words (and the underline of their definition).
    static let maroon = HighlightColor("maroon")

    static let builtIns: [HighlightColor] = [.yellow, .green, .blue, .pink, .orange]

    /// A color from the color wheel.
    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        rawValue = String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    var id: String { rawValue }
    var isCustom: Bool { rawValue.hasPrefix("#") }
    var name: String { isCustom ? "Custom" : rawValue.capitalized }
}

/// Contiguous run of tokens on one raw OCR line (inclusive bounds).
struct TokenSpan: Codable, Hashable {
    var line: Int
    var start: Int
    var end: Int
}

struct Highlight: Codable, Identifiable, Equatable {
    var id: UUID
    /// PDF page index
    var page: Int
    /// The words this highlight covers. Independent of single/spread layout.
    var spans: [TokenSpan]
    /// One rect per text line, normalized to the displayed page.
    var rects: [CGRect]
    var text: String
    var color: HighlightColor
    var created: Date
    /// Key words (their `keywordKey`) this highlight is tagged with. Optional so
    /// highlights saved before tags existed still load.
    var tags: [String]?
    /// Your note / comment on this highlight (the Notes panel).
    var note: String?
    /// "term": a word you circled with the highlighter. "definition": the highlight
    /// made right after it, linked to the word by `termID`. "underline": words you
    /// underlined with the highlighter (no word to define was waiting).
    var role: String?
    var termID: UUID?
    /// Which variation of its color (manual colors: each new highlight in the same color
    /// gets the next shade, so separate points of one idea stay apart). Nil: the color.
    var shade: Int?

    var isTerm: Bool { role == "term" }
    var isDefinition: Bool { role == "definition" }
    /// Drawn as an underline instead of a fill.
    var isUnderlined: Bool { role == "definition" || role == "underline" }

    var tokenKeys: [TokenKey] {
        spans.flatMap { s in
            s.end >= s.start ? (s.start...s.end).map { TokenKey(line: s.line, token: $0) } : []
        }
    }

    var tagKeys: [String] { tags ?? [] }

    /// The note, if it has any text.
    var noteText: String? {
        guard let n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
        return n
    }

    /// A highlight of just a word or short phrase counts as a key word.
    var isKeyword: Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.count <= 5 && text.count <= 50
    }

    /// Groups highlights of the same word / phrase ("Churchill’s" and "churchill").
    var keywordKey: String { Highlight.keywordKey(text) }

    static func keywordKey(_ text: String) -> String {
        keywordDisplay(text).lowercased()
    }

    /// The highlight text tidied up to show as a key word.
    static func keywordDisplay(_ text: String) -> String {
        var t = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        for suffix in ["’s", "'s"] where t.hasSuffix(suffix) {
            t.removeLast(2)
        }
        return t
    }
}

enum NoterError: LocalizedError {
    case unreadablePDF
    case lockedPDF

    var errorDescription: String? {
        switch self {
        case .unreadablePDF: "The file isn't a readable PDF."
        case .lockedPDF: "The PDF is password protected."
        }
    }
}
