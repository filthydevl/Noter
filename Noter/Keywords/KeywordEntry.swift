import Foundation

/// A word or short phrase you highlighted, used as a key word.
struct KeywordEntry: Identifiable {
    /// The normalized key highlights are tagged with (`Highlight.keywordKey`).
    let id: String
    let text: String
    /// The color you highlighted it with most recently; tags use the same color.
    let color: HighlightColor
    /// The places you highlighted it, in book order.
    let mentions: [Highlight]
    /// Highlights you've tagged with it, in book order.
    let linked: [Highlight]
}
