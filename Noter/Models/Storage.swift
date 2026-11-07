import Foundation

/// File layout
///
///   Application Support/Library/<doc-id>/
///       document.pdf        the imported PDF (copied, never modified)
///       info.json           title, page count, last position, layout mode…
///       highlights.json     every highlight (written atomically on each change)
///       cover.jpg           library cover image
///       ocr/index.json      small per-page summary (page numbers, spread split)
///       ocr/p<N>.json       OCR words + boxes for PDF page N
///
///   Documents/Highlights/<title> – Highlights.md
///       plain-text export of the highlights, visible in the Files app.
enum Storage {
    static let libraryRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static let exportFolder: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Highlights", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }()

    static func folder(_ id: UUID) -> URL {
        libraryRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func pdfURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("document.pdf") }
    static func infoURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("info.json") }
    static func highlightsURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("highlights.json") }
    static func thumbnailURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("cover.jpg") }
    static func ocrFolder(_ id: UUID) -> URL { folder(id).appendingPathComponent("ocr", isDirectory: true) }
    static func ocrIndexURL(_ id: UUID) -> URL { ocrFolder(id).appendingPathComponent("index.json") }
    static func ocrVersionsURL(_ id: UUID) -> URL { ocrFolder(id).appendingPathComponent("versions.json") }
    static func ocrPageURL(_ id: UUID, _ page: Int) -> URL { ocrFolder(id).appendingPathComponent("p\(page).json") }

    static func exportURL(for info: DocumentInfo) -> URL {
        exportURL(for: info, "Highlights", ext: "md")
    }

    /// `Documents/Highlights/<title> – <kind>.<ext>`, visible in the Files app.
    static func exportURL(for info: DocumentInfo, _ kind: String, ext: String) -> URL {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let clean = info.title.components(separatedBy: bad).joined(separator: "-")
        let name = clean.isEmpty ? info.id.uuidString : String(clean.prefix(120))
        return exportFolder.appendingPathComponent("\(name) – \(kind).\(ext)")
    }

    /// Every export file of a document (Markdown and PDFs).
    static func exportURLs(for info: DocumentInfo) -> [URL] {
        [exportURL(for: info)] + ["Highlights", "Key words", "Questions"].map { exportURL(for: info, $0, ext: "pdf") }
    }

    /// Atomic write: the old file stays intact until the new one is fully on disk,
    /// so a dead battery mid-save can never corrupt anything.
    @discardableResult
    static func save<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            print("Noter: failed to save \(url.lastPathComponent): \(error)")
            return false
        }
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
