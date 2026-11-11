import SwiftUI

/// Ready-made tags for close reading, there whenever you want them (alongside your own
/// key words): tag a highlight as the thesis, a premise, evidence, a cause or effect…
/// Stored in a highlight's tags like key words, under a key that can't clash with one.
enum AnalysisTag: String, CaseIterable, Identifiable {
    case thesis, claim, argument, premise, evidence, example, assumption
    case cause, effect, counterargument, rebuttal, contrast, context, theme, significance, conclusion

    var id: String { key }

    /// What's stored in `Highlight.tags` ("#cause").
    var key: String { "#" + rawValue }

    static func from(key: String) -> AnalysisTag? {
        key.hasPrefix("#") ? AnalysisTag(rawValue: String(key.dropFirst())) : nil
    }

    var title: String {
        switch self {
        case .counterargument: "Counterargument"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// What it's for, shown in the tag menu's help text.
    var hint: String {
        switch self {
        case .thesis: "The main point of the whole text"
        case .claim: "Something the author asserts"
        case .argument: "Reasoning toward a point"
        case .premise: "A statement an argument rests on"
        case .evidence: "Facts, data or sources offered as support"
        case .example: "A case that illustrates a point"
        case .assumption: "Taken for granted, not argued"
        case .cause: "Why something happened"
        case .effect: "What happened as a result"
        case .counterargument: "An opposing view"
        case .rebuttal: "The answer to an opposing view"
        case .contrast: "A difference or turn (but, however…)"
        case .context: "Background: time, place, situation"
        case .theme: "A recurring idea"
        case .significance: "Why it matters"
        case .conclusion: "Where the reasoning lands"
        }
    }

    var symbol: String {
        switch self {
        case .thesis: "star"
        case .claim: "megaphone"
        case .argument: "arrow.triangle.branch"
        case .premise: "square.stack.3d.down.right"
        case .evidence: "doc.text.magnifyingglass"
        case .example: "lightbulb"
        case .assumption: "questionmark.diamond"
        case .cause: "arrow.right.circle"
        case .effect: "arrow.down.right.circle"
        case .counterargument: "arrow.left.arrow.right"
        case .rebuttal: "arrow.uturn.left"
        case .contrast: "circle.lefthalf.filled"
        case .context: "globe"
        case .theme: "repeat"
        case .significance: "exclamationmark.circle"
        case .conclusion: "flag.checkered"
        }
    }

    /// A color of its own, so the chips stand apart from your key words.
    var color: HighlightColor {
        let hex: String
        switch self {
        case .thesis: hex = "#E0A800"
        case .claim: hex = "#3D7DD8"
        case .argument: hex = "#5B5BD6"
        case .premise: hex = "#7A6FCF"
        case .evidence: hex = "#2E9E6A"
        case .example: hex = "#56B870"
        case .assumption: hex = "#9A8F7A"
        case .cause: hex = "#E46A2E"
        case .effect: hex = "#D9483B"
        case .counterargument: hex = "#B0479C"
        case .rebuttal: hex = "#8E3B9E"
        case .contrast: hex = "#4A9BB5"
        case .context: hex = "#6E8A99"
        case .theme: hex = "#C0657A"
        case .significance: hex = "#C7402F"
        case .conclusion: hex = "#2C6E8F"
        }
        return HighlightColor(rawValue: hex) ?? .yellow
    }

    /// Grouped in the tag menu.
    static let groups: [(String, [AnalysisTag])] = [
        ("Argument", [.thesis, .claim, .argument, .premise, .assumption, .conclusion]),
        ("Support", [.evidence, .example]),
        ("Cause & effect", [.cause, .effect]),
        ("Debate", [.counterargument, .rebuttal, .contrast]),
        ("Reading", [.context, .theme, .significance]),
    ]

    /// Whether the tag menus offer them (on unless you turn them off).
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "noter.analysisTags") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "noter.analysisTags") }
    }
}
