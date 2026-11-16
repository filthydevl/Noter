import SwiftUI

/// The highlight colors of one document: which ones you use (the built-in ones plus any
/// you added from the color wheel), what each one means to you ("Ideas", "Concepts"…)
/// and whether the color changes by itself after every highlight. Names are just a
/// guide for you — they don't change the highlights.
@MainActor
final class ColorPalette: ObservableObject {
    private struct Stored: Codable {
        var colors: [HighlightColor]
        var names: [String: String]
        var autoSwitch: Bool
    }

    /// Colors to highlight with, in order (auto-switch goes through them in this order).
    @Published private(set) var colors: [HighlightColor]
    /// Your name for a color (by `rawValue`).
    @Published private(set) var names: [String: String]
    /// After every highlight, move on to the next color.
    @Published var autoSwitch: Bool {
        didSet { if oldValue != autoSwitch { save() } }
    }

    private let url: URL

    init(docID: UUID) {
        url = Storage.folder(docID).appendingPathComponent("palette.json")
        let stored = Storage.load(Stored.self, from: url)
        colors = stored?.colors.isEmpty == false ? stored!.colors : HighlightColor.builtIns
        names = stored?.names ?? [HighlightColor.maroon.rawValue: "Word"]
        autoSwitch = stored?.autoSwitch ?? false
    }

    private func save() {
        Storage.save(Stored(colors: colors, names: names, autoSwitch: autoSwitch), to: url)
    }

    /// Your name for the color, if you gave it one.
    func name(_ c: HighlightColor) -> String? {
        guard let n = names[c.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else {
            return nil
        }
        return n
    }

    func setName(_ name: String, for c: HighlightColor) {
        guard names[c.rawValue] ?? "" != name else { return }
        names[c.rawValue] = name
        save()
    }

    /// Adds a color from the color wheel (or brings back one already there).
    @discardableResult
    func add(_ ui: UIColor) -> HighlightColor {
        let c = HighlightColor(ui)
        if !colors.contains(c) {
            colors.append(c)
            save()
        }
        return c
    }

    func remove(_ c: HighlightColor) {
        guard colors.count > 1 else { return }
        colors.removeAll { $0 == c }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        colors.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// The color after `c` (auto-switch).
    func next(after c: HighlightColor) -> HighlightColor {
        guard let i = colors.firstIndex(of: c) else { return colors.first ?? .yellow }
        return colors[(i + 1) % colors.count]
    }
}
