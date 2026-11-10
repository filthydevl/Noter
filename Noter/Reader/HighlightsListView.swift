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
        let items = session.groupedHighlights()
        let keywords = session.keywordEntries(includingRemoved: true)
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
                        ForEach(HighlightBlock.blocks(items)) { block in
                            switch block {
                            case .single(let h):
                                VStack(spacing: 6) {
                                    // A circled word's definition comes right after it, with an arrow.
                                    if let word = session.term(of: h) {
                                        DefinitionArrow(word: Highlight.keywordDisplay(word.text))
                                    }
                                    row(h, keywords: keywords, byKey: byKey)
                                }
                            case .run(let run):
                                ConnectedIdeas(run: run, name: session.palette.name(run[0].color)) { h in
                                    row(h, keywords: keywords, byKey: byKey)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                }
                .defaultScrollAnchor(.bottom)
            }
        }
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .onAppear { HighlightExporter.export(session) }
        .sheet(item: $share) { ShareSheet(url: $0.url) }
    }
}

extension HighlightsListView {
    private func row(_ h: Highlight, keywords: [KeywordEntry], byKey: [String: KeywordEntry]) -> HighlightRow {
        HighlightRow(
            highlight: h,
            label: session.pageLabel(for: h),
            tags: h.tagKeys.compactMap { byKey[$0] },
            available: keywords.filter {
                !(h.isKeyword && $0.id == h.keywordKey) && !session.removedKeywords.contains($0.id)
            },
            open: { session.open(h) },
            toggleTag: { session.toggleTag($0, on: h.id) },
            delete: { session.removeHighlights([h.id]) },
            note: h.noteText,
            colorName: session.palette.name(h.color))
    }
}

/// The highlights list in blocks: highlights one after another in the same color are
/// connected ideas and are shown together; circled words and their definitions stand
/// on their own.
enum HighlightBlock: Identifiable {
    case single(Highlight)
    case run([Highlight])

    var id: UUID {
        switch self {
        case .single(let h): h.id
        case .run(let hs): hs[0].id
        }
    }

    static func blocks(_ items: [Highlight]) -> [HighlightBlock] {
        var out: [HighlightBlock] = []
        var run: [Highlight] = []
        func flush() {
            if run.count > 1 {
                out.append(.run(run))
            } else if let h = run.first {
                out.append(.single(h))
            }
            run = []
        }
        for h in items {
            if h.isTerm || h.isDefinition {
                flush()
                out.append(.single(h))
            } else if let last = run.last, last.color != h.color {
                flush()
                run = [h]
            } else {
                run.append(h)
            }
        }
        flush()
        return out
    }
}

/// Successive highlights in the same color: one block, each highlight still its own
/// card, listed with a dash.
struct ConnectedIdeas<Row: View>: View {
    let run: [Highlight]
    let name: String?
    @ViewBuilder let row: (Highlight) -> Row

    var body: some View {
        let color = run[0].color.color
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(name ?? "Connected ideas")
                    .font(.caption.weight(.semibold))
                Text("· \(run.count) in a row")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            ForEach(run) { h in
                HStack(alignment: .top, spacing: 6) {
                    Text("–")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(h.displayColor)
                        .padding(.top, 10)
                        .accessibilityHidden(true)
                    row(h)
                }
            }
        }
        .padding(8)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(color.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(run.count) connected highlights, \(name ?? run[0].color.name)")
    }
}

/// The small "×" next to a Questions / Key words card: takes it off that list only.
struct RemoveCellButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
        .accessibilityLabel(label)
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

/// One highlight card: color, book page, text and the key word tag column. In the
/// Highlights panel its note is shown below; in the Notes panel you write it there.
struct HighlightRow: View {
    let highlight: Highlight
    let label: String
    let tags: [KeywordEntry]
    let available: [KeywordEntry]
    let open: () -> Void
    let toggleTag: (String) -> Void
    let delete: () -> Void
    /// Read-only note (Highlights panel).
    var note: String? = nil
    /// Editable note (Notes panel).
    var editNote: ((String) -> Void)? = nil
    /// The note field gained / lost focus (Notes panel).
    var noteFocused: ((Bool) -> Void)? = nil
    /// Your name for the highlight's color ("Ideas"…).
    var colorName: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            card
            if let editNote {
                NoteEditor(initial: highlight.note ?? "", commit: editNote, focused: noteFocused)
            } else if let note {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Note: \(note)")
            }
        }
        .padding(14)
        .background(Color(.systemBackground).opacity(0.75),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(highlight.displayColor)
                            .frame(width: 8, height: 8)
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if highlight.isTerm || highlight.isDefinition {
                            Text(highlight.isTerm ? "Word" : "Definition")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(HighlightColor.maroon.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(HighlightColor.maroon.color.opacity(0.12), in: Capsule())
                        } else if highlight.role == "underline" {
                            Text(colorName.map { "Underline · \($0)" } ?? "Underline")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(highlight.displayColor.opacity(0.3), in: Capsule())
                        } else if let colorName {
                            Text(colorName)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(highlight.displayColor.opacity(0.3), in: Capsule())
                        }
                        if highlight.isKeyword {
                            Image(systemName: "key")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Key word")
                        }
                    }
                    Text(highlight.text)
                        .underline(highlight.isUnderlined, color: highlight.displayColor)
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
    }
}

/// Points from a circled word's card to its definition's card.
struct DefinitionArrow: View {
    let word: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .bold))
            Text("definition of “\(word)”")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(HighlightColor.maroon.color)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The note field under a highlight in the Notes panel. Grows as you type.
struct NoteEditor: View {
    let initial: String
    let commit: (String) -> Void
    /// Tells the list when you start typing here, so it can scroll the card into view.
    var focused: ((Bool) -> Void)? = nil
    @State private var text = ""
    @State private var loaded = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "square.and.pencil")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            TextField("Add a note or comment…", text: $text, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...14)
                .focused($isFocused)
                .accessibilityLabel("Note")
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            if !loaded {
                text = initial
                loaded = true
            }
        }
        .onChange(of: text) { _, new in
            if loaded { commit(new) }
        }
        .onChange(of: isFocused) { _, f in focused?(f) }
    }
}
