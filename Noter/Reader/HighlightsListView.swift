import SwiftUI
import UIKit

/// Every highlight, in book order, labelled with the page number printed in the book.
/// Tap one to jump to it.
struct HighlightsListView: View {
    @ObservedObject var session: DocumentSession
    @State private var copied = false

    var body: some View {
        let items = session.sortedHighlights()
        let _ = session.labelsVersion // refresh when page numbers improve
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No highlights yet",
                    systemImage: "highlighter",
                    description: Text("Draw over any line with your Apple Pencil — in the PDF or the text view — and it's highlighted and saved here."))
            } else {
                List {
                    Section {
                        ForEach(items) { h in
                            Button {
                                session.open(h)
                            } label: {
                                HighlightRow(highlight: h, label: session.pageLabel(for: h))
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    session.removeHighlights([h.id])
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
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
                    } header: {
                        HStack {
                            Text("\(items.count) highlight\(items.count == 1 ? "" : "s")")
                            Spacer()
                            Button(copied ? "Copied" : "Copy all") {
                                UIPasteboard.general.string = HighlightExporter.plainText(session)
                                copied = true
                            }
                            ShareLink(item: Storage.exportURL(for: session.info)) {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .padding(.leading, 12)
                        }
                        .font(.subheadline)
                        .textCase(nil)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear { HighlightExporter.export(session) }
    }
}

private struct HighlightRow: View {
    let highlight: Highlight
    let label: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(highlight.color.color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(highlight.text)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
