import UIKit

/// How tidied handwriting is lettered.
enum TidyStyle: String, Codable, CaseIterable, Identifiable {
    case handwriting, typed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .handwriting: "Neat handwriting"
        case .typed: "Typed"
        }
    }

    func font(size: CGFloat) -> UIFont {
        switch self {
        case .handwriting:
            UIFont(name: "Noteworthy-Bold", size: size) ?? .systemFont(ofSize: size, weight: .medium)
        case .typed:
            .systemFont(ofSize: size, weight: .medium)
        }
    }
}

/// Handwriting that was tidied into neat lettering. Keeps the original strokes so it
/// can be turned back into your handwriting.
struct InkText: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    /// Normalized to the displayed page (0...1, origin top-left).
    var rect: CGRect
    var colorHex: String
    var style: TidyStyle
    var lines: Int
    /// The handwriting it replaced: a PKDrawing in page points.
    var original: Data?
}

/// Everything drawn on one PDF page: the PencilKit drawing (in page points, origin
/// top-left, so it lines up at any zoom) and tidied text.
struct PageInk: Codable {
    var drawing: Data?
    var texts: [InkText] = []
}

enum InkStore {
    static func folder(_ id: UUID) -> URL {
        Storage.folder(id).appendingPathComponent("ink", isDirectory: true)
    }

    static func url(_ id: UUID, page: Int) -> URL {
        folder(id).appendingPathComponent("p\(page).json")
    }

    static func load(_ id: UUID, page: Int) -> PageInk {
        Storage.load(PageInk.self, from: url(id, page: page)) ?? PageInk()
    }

    static func save(_ ink: PageInk, _ id: UUID, page: Int) {
        try? FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        if ink.drawing == nil && ink.texts.isEmpty {
            try? FileManager.default.removeItem(at: url(id, page: page))
        } else {
            Storage.save(ink, to: url(id, page: page))
        }
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xFF) / 255; g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255; a = CGFloat(v & 0xFF) / 255
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255; a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", c(r), c(g), c(b), c(a))
    }
}
