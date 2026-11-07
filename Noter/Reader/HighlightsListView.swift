import SwiftUI
import UIKit

/// Slide-in panel with every highlight, in book order, labelled with the page number
/// printed in the book. Tap one to jump to it.
struct HighlightsListView: View {
    @ObservedObject var session: DocumentSession
    var onClose: () -> Void

    var body: some View {
        let items = session.sortedHighlights()
        let _ = session.labelsVersion // refresh when page numbers improve
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Highlights")
                        .font(.title3.weight(.semibold))
                    Text("\(items.count) highlight\(items.count == 1 ? "" : "s")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !items.isEmpty {
                    Menu {
                        Button {
                            UIPasteboard.general.string = HighlightExporter.plainText(session)
                            session.showToast("Copied all highlights")
                        } label: {
                            Label("Copy all", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: Storage.exportURL(for: session.info)) {
                            Label("Export Markdown", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        panelIcon("square.and.arrow.up")
                    }
                    .accessibilityLabel("Share highlights")
                }
                Button(action: onClose) { panelIcon("xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close highlights")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            if items.isEmpty {
                ContentUnavailableView(
                    "No highlights yet",
                    systemImage: "highlighter",
                    description: Text("Draw over a line with your Apple Pencil, in the PDF or the text view."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { h in
                            Button {
                                session.open(h)
                            } label: {
                                HighlightRow(highlight: h, label: session.pageLabel(for: h))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = h.text
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                Button(role: .destructive) {
                                    session.removeHighlights([h.id])
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .onAppear { HighlightExporter.export(session) }
    }

    private func panelIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .background(Color.primary.opacity(0.07), in: Circle())
    }
}

private struct HighlightRow: View {
    let highlight: Highlight
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(highlight.color.color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(highlight.text)
                .font(.system(.callout, design: .serif))
                .foregroundStyle(.primary)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color(.systemBackground).opacity(0.75),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}
