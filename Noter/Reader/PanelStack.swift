import SwiftUI

private struct PanelHorizontalKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PanelTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The list is the strip along the bottom (portrait): its cards run side by side.
    var panelHorizontal: Bool {
        get { self[PanelHorizontalKey.self] }
        set { self[PanelHorizontalKey.self] = newValue }
    }

    /// Room at the top of each card's column for the title and buttons floating there.
    var panelTopInset: CGFloat {
        get { self[PanelTopInsetKey.self] }
        set { self[PanelTopInsetKey.self] = newValue }
    }
}

/// The scroll view of a list panel: down the side panel, sideways along the bottom.
struct PanelScroll<Content: View>: View {
    @Environment(\.panelHorizontal) private var horizontal
    /// The panel's title and buttons float over the cards (see `panelHeader`).
    var floatingHeader = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: !horizontal) {
            content()
        }
        .environment(\.panelTopInset, horizontal && floatingHeader ? 46 : 0)
    }
}

/// The cards of a list panel: one under another in the side panel; side by side in
/// the strip along the bottom. Each card marks itself with `.panelCard()`, which there
/// makes it a column of its own (scrolling up and down if it's tall).
struct PanelStack<Content: View>: View {
    @Environment(\.panelHorizontal) private var horizontal
    @ViewBuilder let content: () -> Content

    var body: some View {
        if horizontal {
            HStack(alignment: .top, spacing: 12) { content() }
                .padding(.vertical, 2)
        } else {
            LazyVStack(spacing: 10) { content() }
        }
    }
}

extension View {
    /// One card of a list panel (see `PanelStack`).
    func panelCard() -> some View { modifier(PanelCard()) }

    /// A list panel's title row: slimmer in the strip along the bottom, so the cards
    /// get the room.
    /// `floating`: in the strip along the bottom it takes no room of its own; the title
    /// and buttons float over the top of the cards (pass `floatingHeader` to the
    /// `PanelScroll` below it so the cards start under them).
    func panelHeader(bottom: CGFloat, floating: Bool = false) -> some View {
        modifier(PanelHeader(bottom: bottom, floating: floating))
    }
}

private struct PanelHeader: ViewModifier {
    @Environment(\.panelHorizontal) private var horizontal
    let bottom: CGFloat
    let floating: Bool

    func body(content: Content) -> some View {
        if horizontal && floating {
            content
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .frame(height: 0, alignment: .top)
                .zIndex(1)
        } else if horizontal {
            content
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 6)
        } else {
            content
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, bottom)
        }
    }
}

/// A list panel's title and the count under it; in the strip along the bottom, one
/// small floating label ("Highlights · 63 highlights").
struct PanelTitle: View {
    @Environment(\.panelHorizontal) private var horizontal
    let title: String
    let subtitle: String

    var body: some View {
        if horizontal {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// How wide a card's column is in the strip along the bottom.
private let panelColumnWidth: CGFloat = 400

private struct PanelCard: ViewModifier {
    @Environment(\.panelHorizontal) private var horizontal
    @Environment(\.panelTopInset) private var topInset

    func body(content: Content) -> some View {
        if horizontal {
            // Its own column: full height of the strip, never squeezed (a tall card
            // scrolls inside its column instead of overlapping the next one).
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: panelColumnWidth, alignment: .topLeading)
                    .padding(.bottom, 8)
            }
            // Starts under the floating title; scrolls up beneath it.
            .contentMargins(.top, topInset, for: .scrollContent)
            .frame(width: panelColumnWidth)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            content
        }
    }
}
