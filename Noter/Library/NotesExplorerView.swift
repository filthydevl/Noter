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
    // How the bracket notes look (the customize menu).
    @AppStorage("noter.explorerBracketFont") private var bracketFont = "system"
    @AppStorage("noter.explorerBracketColors") private var bracketColors = BracketLook.Colors.lines.rawValue
    @AppStorage("noter.explorerBracketIndent") private var bracketIndent = 1.2
    @AppStorage("noter.explorerBracketSpacing") private var bracketSpacing = 1.0
    @AppStorage("noter.explorerBracketHeadings") private var bracketHeadings = true
    @AppStorage("noter.explorerBracketQuote") private var bracketQuote = false
    @State private var showBracketLook = false
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
                if mode == .brackets {
                    Button {
                        showBracketLook = true
                    } label: {
                        Label("Customize", systemImage: "textformat.size")
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $showBracketLook, arrowEdge: .top) {
                        bracketLookMenu
                            .presentationCompactAdaptation(.popover)
                    }
                    .accessibilityLabel("Customize bracket notes")
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
        let look = self.look
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
                                if look.headings {
                                    HStack(spacing: 6) {
                                        Text("PDF page \(group.page + 1)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                                    }
                                    .padding(.bottom, 4)
                                }
                                ForEach(group.entries) { e in
                                    BracketLines(entry: e, size: size, look: look)
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

    private var look: BracketLook {
        BracketLook(face: ReaderFont(rawValue: bracketFont),
                    colors: BracketLook.Colors(rawValue: bracketColors) ?? .lines,
                    indent: bracketIndent, spacing: bracketSpacing,
                    headings: bracketHeadings, quote: bracketQuote)
    }

    /// Size, font, indent, line spacing, colors, page headings, the highlighted text.
    private var bracketLookMenu: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bracket notes")
                .font(.headline)

            lookRow("Size") {
                HStack(spacing: 10) {
                    Button {
                        bracketZoom = BracketNotesView.clampZoom(bracketZoom / 1.12)
                    } label: {
                        Image(systemName: "textformat.size.smaller").frame(width: 36, height: 30)
                    }
                    .accessibilityLabel("Smaller")
                    Text("\(Int((bracketZoom * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .frame(minWidth: 48)
                    Button {
                        bracketZoom = BracketNotesView.clampZoom(bracketZoom * 1.12)
                    } label: {
                        Image(systemName: "textformat.size.larger").frame(width: 36, height: 30)
                    }
                    .accessibilityLabel("Larger")
                }
                .buttonStyle(.bordered)
            }

            lookRow("Font") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    fontChoice("system", title: "System", font: .system(size: 15))
                    ForEach(ReaderFont.allCases) { f in
                        fontChoice(f.rawValue, title: f.title, font: Font(f.font(size: 15)))
                    }
                }
            }

            lookRow("Indent") {
                Picker("Indent", selection: $bracketIndent) {
                    Text("Compact").tag(0.8)
                    Text("Normal").tag(1.2)
                    Text("Wide").tag(1.8)
                }
                .pickerStyle(.segmented)
            }

            lookRow("Line spacing") {
                Picker("Line spacing", selection: $bracketSpacing) {
                    Text("Tight").tag(0.5)
                    Text("Normal").tag(1.0)
                    Text("Relaxed").tag(2.0)
                }
                .pickerStyle(.segmented)
            }

            lookRow("Highlight colors") {
                Picker("Highlight colors", selection: $bracketColors) {
                    ForEach(BracketLook.Colors.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }

            Toggle("Page headings", isOn: $bracketHeadings)
            Toggle("Show the highlighted text", isOn: $bracketQuote)

            Button("Reset") {
                bracketZoom = 1
                bracketFont = "system"
                bracketColors = BracketLook.Colors.lines.rawValue
                bracketIndent = 1.2
                bracketSpacing = 1
                bracketHeadings = true
                bracketQuote = false
            }
            .font(.subheadline)
        }
        .padding(20)
        .frame(width: 360)
    }

    private func lookRow<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func fontChoice(_ raw: String, title: String, font: Font) -> some View {
        let on = bracketFont == raw
        return Button {
            bracketFont = raw
        } label: {
            Text(title)
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(on ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(on ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
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
    var look = BracketLook()

    var body: some View {
        let lines = VStack(alignment: .leading, spacing: 3 * size / 15 * look.spacing) {
            if look.quote {
                // The passage the notes were made from.
                Text(entry.highlight.text)
                    .font(.system(size: size * 0.85, design: .serif).italic())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(entry.highlight.displayColor.opacity(0.18))
                    .padding(.bottom, size * 0.3)
            }
            ForEach(Array(BracketNotesView.lines(entry.text).enumerated()), id: \.offset) { _, line in
                if line.text.isEmpty {
                    Color.clear.frame(height: size * 0.6)
                } else {
                    let color = look.colors == .lines ? BracketNotesView.focusColor(line.text, [entry.highlight]) : nil
                    Text(line.text)
                        .font(look.font(size: size, bold: line.depth == 0))
                        .padding(.horizontal, color == nil ? 0 : 4)
                        .background(color?.opacity(0.28) ?? .clear)
                        .padding(.leading, CGFloat(line.depth) * size * look.indent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        if look.colors == .bar {
            // A bar down the side in the highlight's color.
            lines
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(entry.highlight.displayColor)
                        .frame(width: 3)
                }
        } else {
            lines
        }
    }
}

/// How the bracket notes on View Notes look (its customize menu).
struct BracketLook {
    enum Colors: String, CaseIterable, Identifiable {
        case lines, bar, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .lines: "Lines"
            case .bar: "Side bar"
            case .off: "Off"
            }
        }
    }

    /// nil: the system font (as in the reader's panel).
    var face: ReaderFont? = nil
    var colors: Colors = .lines
    /// Each step of depth, as a share of the text size.
    var indent: Double = 1.2
    /// Room between lines (1: as in the panel).
    var spacing: Double = 1
    var headings = true
    var quote = false

    func font(size: CGFloat, bold: Bool) -> Font {
        if let face { return Font(face.font(size: size, bold: bold)) }
        return .system(size: size, weight: bold ? .semibold : .regular)
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
