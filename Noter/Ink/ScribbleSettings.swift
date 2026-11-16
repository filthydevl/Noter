import SwiftUI
import PencilKit

/// Pen types of the scribble tool.
enum InkKind: String, CaseIterable, Identifiable {
    case pen, pencil, marker, fountainPen, monoline, crayon, watercolor

    var id: String { rawValue }

    var pk: PKInkingTool.InkType {
        switch self {
        case .pen: .pen
        case .pencil: .pencil
        case .marker: .marker
        case .fountainPen: .fountainPen
        case .monoline: .monoline
        case .crayon: .crayon
        case .watercolor: .watercolor
        }
    }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .pencil: "Pencil"
        case .marker: "Marker"
        case .fountainPen: "Fountain pen"
        case .monoline: "Monoline"
        case .crayon: "Crayon"
        case .watercolor: "Watercolor"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .pencil: "pencil"
        case .marker: "highlighter"
        case .fountainPen: "pencil.line"
        case .monoline: "scribble"
        case .crayon: "pencil.and.scribble"
        case .watercolor: "paintbrush.pointed"
        }
    }

    /// Width in page points for the size slider's ends.
    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .pen, .fountainPen: 0.8...16
        case .pencil: 0.8...12
        case .monoline: 0.8...14
        case .marker: 4...36
        case .crayon, .watercolor: 4...36
        }
    }
}

/// Ink colors of the scribble tool.
enum InkColor: String, CaseIterable, Identifiable {
    case black, gray, blue, red, green, purple, orange, yellow

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var uiColor: UIColor {
        switch self {
        case .black: UIColor(white: 0.1, alpha: 1)
        case .gray: UIColor(white: 0.5, alpha: 1)
        case .blue: UIColor(red: 0.15, green: 0.40, blue: 0.95, alpha: 1)
        case .red: UIColor(red: 0.90, green: 0.20, blue: 0.20, alpha: 1)
        case .green: UIColor(red: 0.15, green: 0.62, blue: 0.30, alpha: 1)
        case .purple: UIColor(red: 0.50, green: 0.30, blue: 0.85, alpha: 1)
        case .orange: UIColor(red: 0.98, green: 0.55, blue: 0.10, alpha: 1)
        case .yellow: UIColor(red: 0.98, green: 0.80, blue: 0.10, alpha: 1)
        }
    }

    var color: Color { Color(uiColor: uiColor) }
}

enum EraserKind: String, CaseIterable, Identifiable {
    case object, pixel

    var id: String { rawValue }
    var title: String { self == .object ? "Object eraser" : "Pixel eraser" }
    var pk: PKEraserTool.EraserType { self == .object ? .vector : .bitmap }
}

/// Scribble tool settings, remembered between sessions.
@MainActor
final class ScribbleSettings: ObservableObject {
    @Published var kind: InkKind { didSet { save(); onChange?() } }
    @Published var color: InkColor { didSet { save(); onChange?() } }
    /// 0...1 along the pen's width range.
    @Published var size: CGFloat { didSet { save(); onChange?() } }
    @Published var opacity: CGFloat { didSet { save(); onChange?() } }
    @Published var eraser: EraserKind { didSet { save(); onChange?() } }
    @Published var lasso = false { didSet { onChange?() } }
    @Published var ruler = false { didSet { onChange?() } }
    /// A shape tool instead of the pen (not remembered: you come back to the pen).
    @Published var shape: ShapeKind? { didSet { onChange?() } }
    /// Turn handwriting into neat lettering a moment after you stop writing.
    @Published var autoTidy: Bool { didSet { save() } }
    @Published var tidyStyle: TidyStyle { didSet { save() } }

    var onChange: (() -> Void)?

    var width: CGFloat {
        let r = kind.widthRange
        return r.lowerBound + (r.upperBound - r.lowerBound) * size * size // finer control at the thin end
    }

    var inkTool: PKInkingTool {
        PKInkingTool(kind.pk, color: color.uiColor.withAlphaComponent(opacity), width: width)
    }

    private static let key = "noter.scribble."

    init() {
        let d = UserDefaults.standard
        kind = InkKind(rawValue: d.string(forKey: Self.key + "kind") ?? "") ?? .pen
        color = InkColor(rawValue: d.string(forKey: Self.key + "color") ?? "") ?? .blue
        size = d.object(forKey: Self.key + "size") as? CGFloat ?? 0.3
        opacity = d.object(forKey: Self.key + "opacity") as? CGFloat ?? 1
        eraser = EraserKind(rawValue: d.string(forKey: Self.key + "eraser") ?? "") ?? .object
        autoTidy = d.object(forKey: Self.key + "autoTidy") as? Bool ?? true
        tidyStyle = TidyStyle(rawValue: d.string(forKey: Self.key + "tidyStyle") ?? "") ?? .handwriting
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(kind.rawValue, forKey: Self.key + "kind")
        d.set(color.rawValue, forKey: Self.key + "color")
        d.set(Double(size), forKey: Self.key + "size")
        d.set(Double(opacity), forKey: Self.key + "opacity")
        d.set(eraser.rawValue, forKey: Self.key + "eraser")
        d.set(autoTidy, forKey: Self.key + "autoTidy")
        d.set(tidyStyle.rawValue, forKey: Self.key + "tidyStyle")
    }
}
