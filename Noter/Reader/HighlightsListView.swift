import SwiftUI
import UIKit

/// Slide-in panel with every highlight, in book order, labelled with the page number
/// printed in the book. Tap one to jump to it. The column on the right of each
/// highlight holds its key word tags.
struct HighlightsListView: View {
    @Environment(\.panelHorizontal) private var horizontalPanel
    @ObservedObject var session: DocumentSession
    var onClose: () -> Void
    @State private var share: ShareItem?
    @AppStorage("noter.analysisTags") private var showAnalysis = true

    var body: some View {
        let items = session.groupedHighlights()
        let keywords = session.keywordEntries(includingRemoved: true)
        let byKey = session.tagEntriesByKey()
        let _ = session.labelsVersion // refresh when page numbers improve
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                PanelTitle(title: "Highlights", subtitle: "\(items.count) highlight\(items.count == 1 ? "" : "s")")
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
            .panelHeader(bottom: 12, floating: true)

            if items.isEmpty {
                ContentUnavailableView(
                    "No highlights yet",
                    systemImage: "highlighter",
                    description: Text("Draw over a line with your Apple Pencil, in the PDF or the text view."))
                    .frame(maxHeight: .infinity)
            } else {
                PanelScroll(floatingHeader: true) {
                    PanelStack {
                        ForEach(HighlightBlock.blocks(items)) { block in
                            Group {
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
                            case .definition(let term, let parts):
                                WordWithDefinition(term: term, parts: parts) { h in
                                    row(h, keywords: keywords, byKey: byKey)
                                }
                            }
                            }
                            .panelCard()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, horizontalPanel ? 0 : 20)
                }
                .defaultScrollAnchor(horizontalPanel ? .leading : .bottom)
            }
        }
        .frame(maxHeight: .infinity)
        // The Markdown copy in Files, refreshed once the list has slid in (not during).
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            HighlightExporter.export(session)
        }
        .sheet(item: $share) { ShareSheet(url: $0.url) }
    }
}

extension HighlightsListView {
    private func row(_ h: Highlight, keywords: [KeywordEntry], byKey: [String: KeywordEntry]) -> HighlightRow {
        HighlightRow(
            highlight: h,
            label: session.pageLabel(for: h),
            tags: session.tagKeys(of: h).compactMap { byKey[$0] },
            available: keywords.filter {
                !(h.isKeyword && $0.id == h.keywordKey) && !session.removedKeywords.contains($0.id)
            },
            open: { session.open(h) },
            toggleTag: { session.toggleTag($0, on: h.id) },
            delete: { session.removeHighlights([h.id]) },
            // Notes are written here, under the highlight; the Notes list shows only
            // the highlights that have one.
            editNote: { session.setNote($0, on: h.id) },
            colorName: session.palette.name(h.color),
            showAnalysis: showAnalysis,
            cite: { style, quote in session.cite(h, style: style, withQuote: quote) },
            editSource: { session.showSourceDetails = true })
    }
}

/// The highlights list in blocks: highlights one after another in the same color are
/// connected ideas and are shown together; circled words and their definitions stand
/// on their own.
enum HighlightBlock: Identifiable {
    case single(Highlight)
    case run([Highlight])
    /// A circled word and its definition(s), kept together.
    case definition(Highlight, [Highlight])

    var id: UUID {
        switch self {
        case .single(let h): h.id
        case .run(let hs): hs[0].id
        case .definition(let term, _): term.id
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
        var i = 0
        while i < items.count {
            let h = items[i]
            i += 1
            if h.isTerm {
                flush()
                // Its definitions come right after it (see `groupedHighlights`).
                var parts: [Highlight] = []
                while i < items.count, items[i].isDefinition, items[i].termID == h.id {
                    parts.append(items[i])
                    i += 1
                }
                out.append(parts.isEmpty ? .single(h) : .definition(h, parts))
            } else if h.isDefinition {
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

/// A circled word with its definition below it, an arrow between: one block, each still
/// its own card.
struct WordWithDefinition<Row: View>: View {
    let term: Highlight
    let parts: [Highlight]
    @ViewBuilder let row: (Highlight) -> Row

    var body: some View {
        let color = HighlightColor.maroon.color
        VStack(spacing: 6) {
            row(term)
            ForEach(parts) { p in
                DefinitionArrow(word: Highlight.keywordDisplay(term.text))
                row(p)
            }
        }
        .padding(8)
        .background(color.opacity(0.08), in: Rectangle())
        .overlay(Rectangle().strokeBorder(color.opacity(0.3)))
        .accessibilityElement(children: .contain)
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
        .background(color.opacity(0.10), in: Rectangle())
        .overlay(Rectangle().strokeBorder(color.opacity(0.35)))
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
    @Environment(\.panelHorizontal) private var horizontal
    let symbol: String

    var body: some View {
        if horizontal {
            // Floating over the cards in the strip along the bottom.
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.07), in: Circle())
        }
    }
}

/// A key word tag, in the color you highlighted the key word with.
struct TagChip: View {
    let keyword: KeywordEntry

    var body: some View {
        HStack(spacing: 3) {
            if let symbol = keyword.symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(keyword.text)
        }
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
    /// Offer the analysis tags (cause, effect, premise…) in the tag menu.
    var showAnalysis = true
    /// Copy a citation for this highlight (style, with the quote or not).
    var cite: ((CitationStyle, Bool) -> Void)? = nil
    /// Open the book's details for citations.
    var editSource: (() -> Void)? = nil

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
                .background(Color.primary.opacity(0.05), in: Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Note: \(note)")
            }
        }
        .padding(14)
        .padding(.bottom, 4) // clear of the folded corner
        .background { StickyNote(color: highlight.uiColor) }
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
                        if highlight.role == "underline" {
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
                    if showAnalysis {
                        Menu {
                            ForEach(AnalysisTag.groups.indices, id: \.self) { g in
                                Section(AnalysisTag.groups[g].0) {
                                    ForEach(AnalysisTag.groups[g].1) { t in
                                        Button {
                                            toggleTag(t.key)
                                        } label: {
                                            if tags.contains(where: { $0.id == t.key }) {
                                                Label(t.title, systemImage: "checkmark")
                                            } else {
                                                Label(t.title, systemImage: t.symbol)
                                            }
                                            Text(t.hint)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Analysis tags", systemImage: "text.magnifyingglass")
                        }
                    }
                    if available.isEmpty {
                        Text("Highlight a single word or a short phrase to make it a key word.")
                    } else {
                        Section("Tag with key word") {
                            ForEach(available) { k in
                                Button {
                                    toggleTag(k.id)
                                } label: {
                                    if tags.contains(where: { $0.id == k.id }) {
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
                .accessibilityLabel("Tag with key word or analysis tag")
                if let cite {
                    Menu {
                        Section("Chicago") {
                            Button { cite(.chicago, false) } label: { Label("Footnote", systemImage: "text.append") }
                            Button { cite(.chicago, true) } label: { Label("Quote + footnote", systemImage: "text.quote") }
                        }
                        Section("MLA") {
                            Button { cite(.mla, false) } label: {
                                Label("In-text + works cited", systemImage: "text.append")
                            }
                            Button { cite(.mla, true) } label: {
                                Label("Quote + citation", systemImage: "text.quote")
                            }
                        }
                        if let editSource {
                            Button(action: editSource) { Label("Source details…", systemImage: "book.closed") }
                        }
                    } label: {
                        Image(systemName: "quote.closing")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 24)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    .accessibilityLabel("Cite")
                }
            }
            .frame(maxWidth: 120, alignment: .trailing)
        }
    }
}

/// A highlight's card as a sticky note in the highlight's own color: a pastel of it in
/// light mode, a deep tint of it in dark mode (so it sits in with the rest of the app),
/// a faint glue strip along the top, the bottom-right corner folded over, and a soft
/// shadow under it.
struct StickyNote: View {
    let color: UIColor
    @Environment(\.colorScheme) private var scheme

    private static let fold: CGFloat = 16

    var body: some View {
        let dark = scheme == .dark
        let paper = Self.paper(color, dark: dark)
        ZStack(alignment: .bottomTrailing) {
            FoldedPaper(fold: Self.fold)
                .fill(LinearGradient(colors: [Color(uiColor: paper.top), Color(uiColor: paper.bottom)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .top) {
                    // Where the glue is: a touch deeper.
                    Rectangle()
                        .fill(Color.black.opacity(dark ? 0.12 : 0.04))
                        .frame(height: 9)
                }
                .clipShape(FoldedPaper(fold: Self.fold))
                .shadow(color: .black.opacity(dark ? 0.4 : 0.13), radius: 6, x: 0, y: 3)
            // The corner, folded over onto the note.
            FoldFlap()
                .fill(Color(uiColor: paper.flap))
                .frame(width: Self.fold, height: Self.fold)
                .shadow(color: .black.opacity(dark ? 0.35 : 0.14), radius: 1.5, x: -1, y: -1)
        }
        .accessibilityHidden(true)
    }

    /// The paper's colors, from the highlight's.
    static func paper(_ c: UIColor, dark: Bool) -> (top: UIColor, bottom: UIColor, flap: UIColor) {
        let base = c.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !base.getRed(&r, green: &g, blue: &b, alpha: &a) { (r, g, b) = (1, 0.9, 0.4) }
        func mix(_ t: CGFloat, with v: CGFloat) -> UIColor {
            UIColor(red: r * t + v * (1 - t), green: g * t + v * (1 - t), blue: b * t + v * (1 - t), alpha: 1)
        }
        if dark {
            // Over the dark panel: the color, deep and muted.
            let paper = mix(0.34, with: 0.13)
            return (mix(0.37, with: 0.14), paper, mix(0.5, with: 0.2))
        } else {
            // A pastel of the color, like a real note.
            return (mix(0.42, with: 1), mix(0.5, with: 1), mix(0.62, with: 0.86))
        }
    }
}

/// A note with its bottom-right corner folded away.
private struct FoldedPaper: Shape {
    let fold: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The folded-over corner itself (its back showing).
private struct FoldFlap: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Points from a circled word's card to its definition's card.
struct DefinitionArrow: View {
    let word: String

    var body: some View {
        // Just the arrow; VoiceOver still says what it is.
        Image(systemName: "arrow.down")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(HighlightColor.maroon.color)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Goes with \(word)")
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
        .background(Color.primary.opacity(0.05), in: Rectangle())
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
