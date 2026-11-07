import SwiftUI
import UIKit

/// Slide-in panel with every highlight, in book order, labelled with the page number
/// printed in the book. Tap one to jump to it. The column on the right of each
/// highlight holds its key word tags.
struct HighlightsListView: View {
    @ObservedObject var session: DocumentSession
    var onClose: () -> Void
    @State private var share: ShareItem?

    var body: some View {
        let items = session.sortedHighlights()
        let keywords = session.keywordEntries()
        let byKey = Dictionary(uniqueKeysWithValues: keywords.map { ($0.id, $0) })
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
                        Button {
                            if let url = PDFExport.highlights(session) { share = ShareItem(url: url) }
                        } label: {
                            Label("Export PDF", systemImage: "doc.richtext")
                        }
                        ShareLink(item: Storage.exportURL(for: session.info)) {
                            Label("Export Markdown", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        PanelIcon(symbol: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share highlights")
                }
                Button(action: onClose) { PanelIcon(symbol: "xmark") }
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
                            HighlightRow(
                                highlight: h,
                                label: session.pageLabel(for: h),
                                tags: h.tagKeys.compactMap { byKey[$0] },
                                available: keywords.filter { !(h.isKeyword && $0.id == h.keywordKey) },
                                open: { session.open(h) },
                                toggleTag: { session.toggleTag($0, on: h.id) },
                                delete: { session.removeHighlights([h.id]) })
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
        .sheet(item: $share) { ShareSheet(url: $0.url) }
    }
}

struct PanelIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .background(Color.primary.opacity(0.07), in: Circle())
    }
}

/// A key word tag, in the color you highlighted the key word with.
struct TagChip: View {
    let keyword: KeywordEntry

    var body: some View {
        Text(keyword.text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(keyword.color.color.opacity(0.35), in: Capsule())
            .overlay(Capsule().strokeBorder(keyword.color.color, lineWidth: 1))
    }
}

private struct HighlightRow: View {
    let highlight: Highlight
    let label: String
    let tags: [KeywordEntry]
    let available: [KeywordEntry]
    let open: () -> Void
    let toggleTag: (String) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(highlight.color.color)
                            .frame(width: 8, height: 8)
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if highlight.isKeyword {
                            Image(systemName: "key")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Key word")
                        }
                    }
                    Text(highlight.text)
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(.primary)
                        .lineLimit(8)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = highlight.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button(role: .destructive, action: delete) {
                    Label("Delete", systemImage: "trash")
                }
            }

            // Tag column.
            VStack(alignment: .trailing, spacing: 5) {
                ForEach(tags) { TagChip(keyword: $0) }
                Menu {
                    if available.isEmpty {
                        Text("Highlight a single word or a short phrase to make it a key word.")
                    } else {
                        Section("Tag with key word") {
                            ForEach(available) { k in
                                Button {
                                    toggleTag(k.id)
                                } label: {
                                    if highlight.tagKeys.contains(k.id) {
                                        Label(k.text, systemImage: "checkmark")
                                    } else {
                                        Text(k.text)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: tags.isEmpty ? "tag" : "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 24)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                .accessibilityLabel("Tag with key word")
            }
            .frame(maxWidth: 120, alignment: .trailing)
        }
        .padding(14)
        .background(Color(.systemBackground).opacity(0.75),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
