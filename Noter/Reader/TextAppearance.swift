import UIKit

/// Page color of the Text view.
enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
    case system, light, sepia, gray, dark, black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .sepia: "Sepia"
        case .gray: "Gray"
        case .dark: "Dark"
        case .black: "Black"
        }
    }

    var background: UIColor {
        switch self {
        case .system: .systemBackground
        case .light: .white
        case .sepia: UIColor(red: 0.965, green: 0.933, blue: 0.863, alpha: 1)
        case .gray: UIColor(red: 0.23, green: 0.23, blue: 0.24, alpha: 1)
        case .dark: UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        case .black: .black
        }
    }

    var text: UIColor {
        switch self {
        case .system: .label
        case .light: UIColor(white: 0.11, alpha: 1)
        case .sepia: UIColor(red: 0.29, green: 0.23, blue: 0.16, alpha: 1)
        case .gray: UIColor(white: 0.90, alpha: 1)
        case .dark: UIColor(white: 0.88, alpha: 1)
        case .black: UIColor(white: 0.80, alpha: 1)
        }
    }

    /// Titles, headings and sub-headings: a color that stands out from the text and
    /// shows clearly on this page color (also used for the page slider's labels).
    var heading: UIColor {
        switch self {
        case .system:
            UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.55, green: 0.76, blue: 1.0, alpha: 1)
                : UIColor(red: 0.10, green: 0.32, blue: 0.68, alpha: 1) }
        case .light: UIColor(red: 0.10, green: 0.32, blue: 0.68, alpha: 1)
        case .sepia: UIColor(red: 0.62, green: 0.25, blue: 0.08, alpha: 1)
        case .gray: UIColor(red: 1.0, green: 0.82, blue: 0.48, alpha: 1)
        case .dark: UIColor(red: 0.55, green: 0.76, blue: 1.0, alpha: 1)
        case .black: UIColor(red: 0.62, green: 0.80, blue: 1.0, alpha: 1)
        }
    }

    /// Page labels, dimmed (skipped) text.
    var secondary: UIColor {
        switch self {
        case .system: .tertiaryLabel
        case .light: UIColor(white: 0.55, alpha: 1)
        case .sepia: UIColor(red: 0.55, green: 0.46, blue: 0.36, alpha: 1)
        case .gray: UIColor(white: 0.62, alpha: 1)
        case .dark, .black: UIColor(white: 0.52, alpha: 1)
        }
    }

    /// So highlights / read-along tints pick their light or dark strength.
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light, .sepia: .light
        case .gray, .dark, .black: .dark
        }
    }
}

enum ReaderFont: String, Codable, CaseIterable, Identifiable {
    case newYork, charter, georgia, palatino, sanFrancisco, rounded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newYork: "New York"
        case .charter: "Charter"
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .sanFrancisco: "San Francisco"
        case .rounded: "Rounded"
        }
    }

    func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        let system = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        func design(_ d: UIFontDescriptor.SystemDesign) -> UIFont {
            system.fontDescriptor.withDesign(d).map { UIFont(descriptor: $0, size: size) } ?? system
        }
        let base: UIFont
        switch self {
        case .newYork: base = design(.serif)
        case .sanFrancisco: base = system
        case .rounded: base = design(.rounded)
        case .charter: base = UIFont(name: bold ? "Charter-Bold" : "Charter-Roman", size: size) ?? design(.serif)
        case .georgia: base = UIFont(name: bold ? "Georgia-Bold" : "Georgia", size: size) ?? design(.serif)
        case .palatino: base = UIFont(name: bold ? "Palatino-Bold" : "Palatino-Roman", size: size) ?? design(.serif)
        }
        guard italic, let d = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return base }
        return UIFont(descriptor: d, size: size)
    }
}

/// How wide the column of text may get.
enum ReaderWidth: String, Codable, CaseIterable, Identifiable {
    case narrow, medium, wide, full

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var points: CGFloat {
        switch self {
        case .narrow: 560
        case .medium: 740
        case .wide: 960
        case .full: .greatestFiniteMagnitude
        }
    }
}

/// Text view reading options (font size lives in `DocumentSession.transcriptFontSize`).
struct TextAppearance: Codable, Equatable {
    var theme: ReaderTheme = .system
    var font: ReaderFont = .newYork
    /// Extra space between lines, as a fraction of the font size.
    var lineSpacing: Double = 0.38
    /// Extra space between paragraphs, as a fraction of the font size.
    var paragraphSpacing: Double = 0.9
    var width: ReaderWidth = .medium
    var justified = false
    /// In landscape, two pages side by side like an open book. Optional so options saved
    /// before it existed still load.
    var twoPagesInLandscape: Bool?

    var twoPages: Bool {
        get { twoPagesInLandscape ?? false }
        set { twoPagesInLandscape = newValue }
    }

    private static let key = "noter.textAppearance"

    static func load() -> TextAppearance {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(TextAppearance.self, from: data) else { return TextAppearance() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // MARK: Text attributes

    func bodyAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = size * lineSpacing
        paragraph.paragraphSpacing = size * paragraphSpacing
        paragraph.alignment = justified ? .justified : .natural
        paragraph.hyphenationFactor = justified ? 0.9 : 0.2
        return [.font: font.font(size: size), .foregroundColor: theme.text, .paragraphStyle: paragraph]
    }

    func headingAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = size * 0.15
        paragraph.paragraphSpacingBefore = size * 0.6
        paragraph.paragraphSpacing = size * 0.55
        return [.font: font.font(size: size * 1.3, bold: true), .foregroundColor: theme.heading,
                .paragraphStyle: paragraph]
    }

    /// Footnotes: smaller type, like at the foot of a printed page.
    func footnoteAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = size * 0.78 * lineSpacing * 0.8
        paragraph.paragraphSpacing = size * 0.35
        paragraph.paragraphSpacingBefore = size * 0.2
        return [.font: font.font(size: size * 0.78), .paragraphStyle: paragraph]
    }

    func noteAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: font.font(size: size * 0.8, italic: true), .foregroundColor: theme.secondary]
    }
}
