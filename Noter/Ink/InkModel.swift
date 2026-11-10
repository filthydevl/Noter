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
    /// Optional so pages saved before shapes existed still load.
    var shapes: [InkShape]?
}

/// The shapes on the scribble toolbar.
enum ShapeKind: String, Codable, CaseIterable, Identifiable {
    case rectangle, oval, triangle, line, arrow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: "Rectangle"
        case .oval: "Oval"
        case .triangle: "Triangle"
        case .line: "Line"
        case .arrow: "Arrow"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .oval: "oval"
        case .triangle: "triangle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        }
    }

    /// Lines and arrows are reshaped by their two ends; the rest by the corners of their box.
    var isLine: Bool { self == .line || self == .arrow }
}

/// A shape drawn with the shape tool. Stays editable: drag it to move it, or its
/// handles to reshape it.
struct InkShape: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: ShapeKind
    /// Normalized to the displayed page (0...1, origin top-left): opposite corners of
    /// the shape's box, or a line's two ends (an arrow points at `b`).
    var a: CGPoint
    var b: CGPoint
    var colorHex: String
    /// Line width in page points.
    var width: CGFloat

    /// The outline in a space of `size` (the page in points, or a view showing it);
    /// `unit` is that space's points per page point.
    func path(in size: CGSize, unit: CGFloat) -> CGPath {
        let p = CGPoint(x: a.x * size.width, y: a.y * size.height)
        let q = CGPoint(x: b.x * size.width, y: b.y * size.height)
        let box = CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
        let path = CGMutablePath()
        switch kind {
        case .rectangle:
            path.addRect(box)
        case .oval:
            path.addEllipse(in: box)
        case .triangle:
            path.move(to: CGPoint(x: box.midX, y: box.minY))
            path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
            path.addLine(to: CGPoint(x: box.minX, y: box.maxY))
            path.closeSubpath()
        case .line, .arrow:
            path.move(to: p)
            path.addLine(to: q)
            let length = hypot(q.x - p.x, q.y - p.y)
            if kind == .arrow, length > 1 {
                let head = min(max(width * unit * 4, 10 * unit), length * 0.5)
                let angle = atan2(q.y - p.y, q.x - p.x)
                for side in [CGFloat.pi * 0.83, -CGFloat.pi * 0.83] {
                    path.move(to: q)
                    path.addLine(to: CGPoint(x: q.x + head * cos(angle + side), y: q.y + head * sin(angle + side)))
                }
            }
        }
        return path
    }

    /// Draws it into a context whose space is `size` (see `path`).
    func draw(in context: CGContext, size: CGSize, unit: CGFloat) {
        context.saveGState()
        context.setStrokeColor((UIColor(hex: colorHex) ?? .black).cgColor)
        context.setLineWidth(max(width * unit, 0.5))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path(in: size, unit: unit))
        context.strokePath()
        context.restoreGState()
    }
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
        if ink.drawing == nil && ink.texts.isEmpty && (ink.shapes ?? []).isEmpty {
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
