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
/// the strip along the bottom, each its own column (scrolls if it's tall).
struct PanelStack<Content: View>: View {
    @Environment(\.panelHorizontal) private var horizontal
    @ViewBuilder let content: () -> Content

    var body: some View {
        if horizontal {
            // Not lazy: a lazy row starting scrolled to its end (the newest) can pile
            // its columns on top of each other before it has measured them.
            HStack(alignment: .top, spacing: 12) {
                Group { content() }.modifier(PanelColumn())
            }
            .padding(.vertical, 2)
        } else {
            LazyVStack(spacing: 10) { content() }
        }
    }
}

private struct PanelColumn: ViewModifier {
    func body(content: Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .frame(width: 320, alignment: .topLeading)
                .padding(.bottom, 8)
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
