import SwiftUI

/// "View Notes": one reading's highlights, your notes and its bracket notes on a page
/// of their own — as a list, or as a map of connected ideas (highlights joined when
/// they're one idea in the same color, linked to a circled word, or share a tag).
/// What's shown is up to you: which colors, only highlights with a note, bracket
/// notes or not.
struct NotesExplorerView: View {
    let doc: DocumentInfo
    /// Opens the reading (at a page).
    var openBook: (Int) -> Void = { _ in }

    enum Mode: String, CaseIterable, Identifiable {
        case graph, list, brackets
        var id: String { rawValue }
        var title: String {
            switch self {
            case .graph: "Map"
            case .list: "List"
            case .brackets: "Bracket notes"
            }
        }
    }

    @AppStorage("noter.explorerMode") private var modeRaw = Mode.graph.rawValue
    @AppStorage("noter.explorerNotedOnly") private var notedOnly = false
    @AppStorage("noter.explorerTags") private var linkTags = true
    /// The Bracket Notes panel's text size, shared.
    @AppStorage("noter.bracketZoom") private var bracketZoom = 1.0
    @GestureState private var bracketPinch = 1.0
    @State private var hiddenColors = Set<String>()
    @State private var highlights: [Highlight] = []
    @State private var brackets: [String: BracketNotes.Entry] = [:]
    @State private var selected: UUID?

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .graph }

    /// In reading order: page, then down the page.
    private var shown: [Highlight] {
        highlights
            .filter { !hiddenColors.contains($0.color.rawValue) }
            .filter { !notedOnly || $0.noteText != nil }
    }

    private var colorsPresent: [HighlightColor] {
        var seen = Set<String>()
        return highlights.map(\.color).filter { seen.insert($0.rawValue).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if highlights.isEmpty {
                ContentUnavailableView("No highlights yet", systemImage: "highlighter",
                                       description: Text("Highlight in the reading; your highlights, notes and bracket notes gather here."))
                    .frame(maxHeight: .infinity)
            } else if mode == .graph {
                IdeaGraph(highlights: shown, title: LibraryTitles.title(of: doc), linkTags: linkTags, selected: $selected)
                    .overlay(alignment: .bottom) {
                        if let id = selected, let h = shown.first(where: { $0.id == id }) {
                            card(h, compact: true)
                                .frame(maxWidth: 560)
                                .padding(16)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.snappy(duration: 0.25), value: selected)
            } else if mode == .brackets {
                bracketDocument
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(shown) { h in card(h, compact: false) }
                    }
                    .padding(20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(LibraryTitles.title(of: doc))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openBook(doc.lastPage)
                } label: {
                    Label("Open reading", systemImage: "book")
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        let all = Storage.load([Highlight].self, from: Storage.highlightsURL(doc.id)) ?? []
        highlights = all.sorted { a, b in
            if a.page != b.page { return a.page < b.page }
            let ya = a.rects.first?.minY ?? 0, yb = b.rects.first?.minY ?? 0
            if abs(ya - yb) > 0.004 { return ya < yb }
            return (a.rects.first?.minX ?? 0) < (b.rects.first?.minX ?? 0)
        }
        brackets = Storage.load([String: BracketNotes.Entry].self,
                                from: Storage.folder(doc.id).appendingPathComponent("bracket-notes.json")) ?? [:]
    }

    // MARK: Controls

    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Picker("View", selection: $modeRaw) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                Divider().frame(height: 24)

                ForEach(colorsPresent, id: \.rawValue) { c in
                    let on = !hiddenColors.contains(c.rawValue)
                    Button {
                        if on { hiddenColors.insert(c.rawValue) } else { hiddenColors.remove(c.rawValue) }
                    } label: {
                        Circle()
                            .fill(c.color)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0.6 : 0.1), lineWidth: on ? 2 : 1))
                            .opacity(on ? 1 : 0.3)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(c.name) highlights")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }

                Divider().frame(height: 24)

                Toggle("With notes only", isOn: $notedOnly).toggleStyle(.button)
                if mode == .graph {
                    Toggle("Link related ideas", isOn: $linkTags).toggleStyle(.button)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
    }

    // MARK: Bracket notes

    /// Just the bracket notes, one after another in reading order, as one page of
    /// text (no cells). Long press a note to go to its page.
    private var bracketDocument: some View {
        let entries = shown.compactMap { h -> BracketEntry? in
            guard let t = brackets["h-\(h.id.uuidString)"]?.text,
                  !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return BracketEntry(id: h.id, page: h.page, text: t, highlight: h)
        }
        // By page, like the Bracket Notes panel in the reader.
        var pages: [BracketPage] = []
        for e in entries {
            if pages.last?.page == e.page {
                pages[pages.count - 1].entries.append(e)
            } else {
                pages.append(BracketPage(page: e.page, entries: [e]))
            }
        }
        let size = CGFloat(15 * BracketNotesView.clampZoom(bracketZoom * bracketPinch))
        return Group {
            if entries.isEmpty {
                ContentUnavailableView("No bracket notes yet", systemImage: "text.alignleft",
                                       description: Text("Open the Bracket Notes panel in the reading to make them."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(pages) { group in
                            VStack(alignment: .leading, spacing: 3 * size / 15) {
                                // The page, with a hairline to the edge.
                                HStack(spacing: 6) {
                                    Text("PDF page \(group.page + 1)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                                }
                                .padding(.bottom, 4)
                                ForEach(group.entries) { e in
                                    BracketLines(entry: e, size: size)
                                        .contentShape(Rectangle())
                                        .contextMenu {
                                            Button { openBook(e.page) } label: {
                                                Label("Go to PDF page \(e.page + 1)", systemImage: "arrow.up.right")
                                            }
                                        }
                                        .padding(.bottom, size * 0.5)
                                }
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                // Pinch to make the notes bigger or smaller (the same size as the panel's).
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($bracketPinch) { v, s, _ in s = Double(v.magnification) }
                        .onEnded { v in bracketZoom = BracketNotesView.clampZoom(bracketZoom * Double(v.magnification)) })
            }
        }
    }

    // MARK: A highlight

    private func card(_ h: Highlight, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(h.displayColor).frame(width: 9, height: 9)
                Text("PDF page \(h.page + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    openBook(h.page)
                } label: {
                    Label("Go to", systemImage: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
            Text(h.text)
                .font(.callout)
                .lineLimit(compact ? 4 : nil)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(h.displayColor.opacity(0.22))
            if let note = h.noteText {
                Label(note, systemImage: "text.bubble")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(compact ? 3 : nil)
            }
            if compact, let notes = brackets["h-\(h.id.uuidString)"]?.text, !notes.isEmpty {
                BracketText(text: notes)
                    .lineLimit(compact ? 6 : nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(alignment: .leading) { Rectangle().fill(h.displayColor).frame(width: 3) }
    }
}

private struct BracketPage: Identifiable {
    let page: Int
    var entries: [BracketEntry]
    var id: Int { page }
}

private struct BracketEntry: Identifiable {
    let id: UUID
    let page: Int
    let text: String
    let highlight: Highlight
}

/// One highlight's bracket notes drawn the way the reader's Bracket Notes panel draws
/// them: the first line of each idea in semibold, deeper lines indented, and the lines
/// made from the highlight tinted in its color.
private struct BracketLines: View {
    let entry: BracketEntry
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * size / 15) {
            ForEach(Array(BracketNotesView.lines(entry.text).enumerated()), id: \.offset) { _, line in
                if line.text.isEmpty {
                    Color.clear.frame(height: size * 0.6)
                } else {
                    let color = BracketNotesView.focusColor(line.text, [entry.highlight])
                    Text(line.text)
                        .font(.system(size: size, weight: line.depth == 0 ? .semibold : .regular))
                        .padding(.horizontal, color == nil ? 0 : 4)
                        .background(color?.opacity(0.28) ?? .clear)
                        .padding(.leading, CGFloat(line.depth) * size * 1.2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Bracket notes with their tabs as indents.
private struct BracketText: View {
    let text: String
    /// The bracket-notes page: bigger, in the text color.
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? 3 : 2) {
            ForEach(Array(BracketNotesView.lines(text).enumerated()), id: \.offset) { _, line in
                if !line.text.isEmpty {
                    Text(line.text)
                        .font(prominent ? .body : .footnote)
                        .fontWeight(line.depth == 0 ? .semibold : .regular)
                        .foregroundStyle(prominent && line.depth > 0 ? .secondary : (prominent ? .primary : .secondary))
                        .padding(.leading, CGFloat(line.depth) * (prominent ? 22 : 14))
                }
            }
        }
    }
}
