import SwiftUI

/// The slider at the bottom: where you are in the book (the same place in the PDF and
/// Text views). Drag it to move through the book.
struct PageScrubber: View {
    @ObservedObject var session: DocumentSession
    @State private var dragging: Double?
    @State private var lastSent: Int?

    var body: some View {
        let count = session.pageCount
        let value = dragging ?? Double(session.currentPage)
        let page = Int(value.rounded())
        HStack(spacing: 12) {
            Text(title(page))
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .frame(minWidth: 70, alignment: .leading)
            Slider(
                value: Binding(
                    get: { value },
                    set: { v in
                        dragging = v
                        let i = Int(v.rounded())
                        guard i != lastSent else { return }
                        lastSent = i
                        session.goToPage(i)
                    }),
                in: 0...Double(max(count - 1, 1)), step: 1,
                onEditingChanged: { editing in
                    if !editing {
                        dragging = nil
                        lastSent = nil
                    }
                })
            .accessibilityLabel("Page")
            .accessibilityValue(title(page))
            Text("\(page + 1)/\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
    }

    /// "p. 24" (the book's page number) or "PDF 13".
    private func title(_ index: Int) -> String {
        let _ = session.labelsVersion
        let label = session.label(for: SlotKey(pdfIndex: index, half: 0))
        return label.hasPrefix("PDF page") ? "PDF \(index + 1)" : label
    }
}
