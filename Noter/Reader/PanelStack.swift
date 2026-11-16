import SwiftUI

private struct PanelHorizontalKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The list is the strip along the bottom (portrait): its cards run side by side.
    var panelHorizontal: Bool {
        get { self[PanelHorizontalKey.self] }
        set { self[PanelHorizontalKey.self] = newValue }
    }
}

/// The scroll view of a list panel: down the side panel, sideways along the bottom.
struct PanelScroll<Content: View>: View {
    @Environment(\.panelHorizontal) private var horizontal
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: !horizontal) {
            content()
        }
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
    func panelHeader(bottom: CGFloat) -> some View { modifier(PanelHeader(bottom: bottom)) }
}

private struct PanelHeader: ViewModifier {
    @Environment(\.panelHorizontal) private var horizontal
    let bottom: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20)
            .padding(.top, horizontal ? 10 : 18)
            .padding(.bottom, horizontal ? 6 : bottom)
    }
}

/// How wide a card's column is in the strip along the bottom.
private let panelColumnWidth: CGFloat = 400

private struct PanelCard: ViewModifier {
    @Environment(\.panelHorizontal) private var horizontal

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
            .frame(width: panelColumnWidth)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            content
        }
    }
}
