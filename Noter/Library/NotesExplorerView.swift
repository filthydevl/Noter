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
        case graph, list
        var id: String { rawValue }
        var title: String { self == .graph ? "Map" : "List" }
    }

    @AppStorage("noter.explorerMode") private var modeRaw = Mode.graph.rawValue
    @AppStorage("noter.explorerNotedOnly") private var notedOnly = false
    @AppStorage("noter.explorerBrackets") private var showBrackets = true
    @AppStorage("noter.explorerTags") private var linkTags = true
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
                IdeaGraph(highlights: shown, linkTags: linkTags, selected: $selected)
                    .overlay(alignment: .bottom) {
                        if let id = selected, let h = shown.first(where: { $0.id == id }) {
                            card(h, compact: true)
                                .frame(maxWidth: 560)
                                .padding(16)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.snappy(duration: 0.25), value: selected)
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
                .frame(width: 160)

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
                if mode == .list {
                    Toggle("Bracket notes", isOn: $showBrackets).toggleStyle(.button)
                } else {
                    Toggle("Link shared tags", isOn: $linkTags).toggleStyle(.button)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
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
            if showBrackets || compact, let notes = brackets["h-\(h.id.uuidString)"]?.text, !notes.isEmpty {
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

/// Bracket notes with their tabs as indents.
private struct BracketText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(BracketNotesView.lines(text).enumerated()), id: \.offset) { _, line in
                if !line.text.isEmpty {
                    Text(line.text)
                        .font(.footnote)
                        .fontWeight(line.depth == 0 ? .semibold : .regular)
                        .padding(.leading, CGFloat(line.depth) * 14)
                }
            }
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - The map

/// Highlights as dots in their colors, joined where they're connected: one idea
/// across highlights in a row in the same color (strong line), passages linked to a
/// circled word (strong line), and highlights sharing a tag (light line). Laid out by
/// a force simulation, so connected ideas cluster. Drag to move around, pinch to zoom,
/// tap a dot to read it.
private struct IdeaGraph: View {
    let highlights: [Highlight]
    let linkTags: Bool
    @Binding var selected: UUID?

    struct Edge: Hashable {
        let a: Int, b: Int
        let strong: Bool
    }

    @State private var positions: [CGPoint] = []
    @State private var edges: [Edge] = []
    @State private var laidOutFor: [UUID] = []
    @State private var offset = CGSize.zero
    @State private var scale: CGFloat = 1
    @GestureState private var drag = CGSize.zero
    @GestureState private var pinch: CGFloat = 1
    @State private var fitted = false

    var body: some View {
        GeometryReader { g in
            let total = CGSize(width: offset.width + drag.width, height: offset.height + drag.height)
            let zoom = scale * pinch
            Canvas { ctx, size in
                guard positions.count == highlights.count else { return }
                let centre = CGPoint(x: size.width / 2 + total.width, y: size.height / 2 + total.height)
                func place(_ p: CGPoint) -> CGPoint { CGPoint(x: centre.x + p.x * zoom, y: centre.y + p.y * zoom) }
                for e in edges {
                    var path = Path()
                    path.move(to: place(positions[e.a]))
                    path.addLine(to: place(positions[e.b]))
                    ctx.stroke(path, with: .color(highlights[e.a].displayColor.opacity(e.strong ? 0.75 : 0.25)),
                               style: StrokeStyle(lineWidth: e.strong ? 2 : 1, dash: e.strong ? [] : [4, 4]))
                }
                for (i, h) in highlights.enumerated() {
                    let p = place(positions[i])
                    let on = h.id == selected
                    let r: CGFloat = on ? 11 : (h.noteText != nil ? 8 : 6.5)
                    let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                    ctx.fill(dot, with: .color(h.displayColor))
                    if on || h.noteText != nil {
                        ctx.stroke(dot, with: .color(.primary.opacity(on ? 0.9 : 0.35)), lineWidth: on ? 2.5 : 1)
                    }
                    if on || zoom > 1.4 {
                        let words = h.text.split(separator: " ").prefix(5).joined(separator: " ")
                        ctx.draw(Text(words).font(.caption2).foregroundStyle(.secondary),
                                 at: CGPoint(x: p.x, y: p.y + r + 9))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onEnded { v in
                        offset.width += v.translation.width
                        offset.height += v.translation.height
                    })
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { v, s, _ in s = v.magnification }
                    .onEnded { v in scale = min(max(scale * v.magnification, 0.2), 6) })
            .simultaneousGesture(
                SpatialTapGesture().onEnded { t in
                    selected = nearest(to: t.location, in: g.size, offset: total, zoom: zoom)
                })
            .overlay(alignment: .topTrailing) { legend.padding(14) }
            .task(id: highlights.map(\.id) + [UUID(uuidString: linkTags ? "00000000-0000-0000-0000-000000000001" : "00000000-0000-0000-0000-000000000000")!]) {
                await layout(fitting: g.size)
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Rectangle().frame(width: 18, height: 2)
                Text("Connected idea / linked")
            }
            if linkTags {
                HStack(spacing: 6) {
                    Rectangle().frame(width: 18, height: 1).opacity(0.5)
                    Text("Shared tag")
                }
            }
            HStack(spacing: 6) {
                Circle().strokeBorder(Color.primary.opacity(0.5)).frame(width: 10, height: 10)
                Text("Has a note")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func nearest(to p: CGPoint, in size: CGSize, offset: CGSize, zoom: CGFloat) -> UUID? {
        guard positions.count == highlights.count else { return nil }
        let centre = CGPoint(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
        var best: (Int, CGFloat)?
        for (i, q) in positions.enumerated() {
            let s = CGPoint(x: centre.x + q.x * zoom, y: centre.y + q.y * zoom)
            let d = hypot(s.x - p.x, s.y - p.y)
            if d < 26, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best.map { highlights[$0.0].id }
    }

    /// Which highlights are joined.
    static func links(_ hs: [Highlight], tags: Bool) -> [Edge] {
        var out = Set<Edge>()
        let index = Dictionary(uniqueKeysWithValues: hs.enumerated().map { ($0.element.id, $0.offset) })
        // One idea across highlights in a row, in the same color.
        for i in hs.indices.dropFirst() where hs[i].color == hs[i - 1].color && !hs[i].isTerm && !hs[i - 1].isTerm {
            out.insert(Edge(a: i - 1, b: i, strong: true))
        }
        // Passages linked to a circled word.
        for (i, h) in hs.enumerated() {
            if let t = h.termID, let j = index[t] { out.insert(Edge(a: j, b: i, strong: true)) }
        }
        // A tag in common (key words, analysis tags).
        if tags {
            var byTag: [String: [Int]] = [:]
            for (i, h) in hs.enumerated() {
                for t in h.tagKeys { byTag[t, default: []].append(i) }
                if h.isKeyword { byTag[h.keywordKey, default: []].append(i) }
            }
            for members in byTag.values where members.count > 1 {
                for k in members.indices.dropFirst() {
                    out.insert(Edge(a: members[k - 1], b: members[k], strong: false))
                }
            }
        }
        return Array(out)
    }

    /// A force-directed layout (connected highlights pull together, all push apart),
    /// worked out off the main thread.
    private func layout(fitting size: CGSize) async {
        let hs = highlights
        let edges = Self.links(hs, tags: linkTags)
        let n = hs.count
        guard n > 0 else { positions = []; self.edges = []; return }
        let result = await Task.detached(priority: .userInitiated) { () -> [CGPoint] in
            var p = (0..<n).map { i -> CGPoint in
                let a = Double(i) * 2.399963, r = 18 * sqrt(Double(i) + 1)
                return CGPoint(x: r * cos(a), y: r * sin(a))
            }
            let k = 60.0
            var temperature = 40.0
            let rounds = n > 300 ? 120 : 260
            for _ in 0..<rounds {
                var d = [CGVector](repeating: .zero, count: n)
                for i in 0..<n {
                    for j in (i + 1)..<n {
                        var dx = Double(p[i].x - p[j].x), dy = Double(p[i].y - p[j].y)
                        var dist = sqrt(dx * dx + dy * dy)
                        if dist < 0.01 { dx = 0.1; dy = 0.1; dist = 0.14 }
                        let f = k * k / dist
                        let fx = dx / dist * f, fy = dy / dist * f
                        d[i].dx += fx; d[i].dy += fy
                        d[j].dx -= fx; d[j].dy -= fy
                    }
                }
                for e in edges {
                    let dx = Double(p[e.a].x - p[e.b].x), dy = Double(p[e.a].y - p[e.b].y)
                    let dist = max(sqrt(dx * dx + dy * dy), 0.01)
                    let f = dist * dist / k * (e.strong ? 1.6 : 0.5)
                    let fx = dx / dist * f, fy = dy / dist * f
                    d[e.a].dx -= fx; d[e.a].dy -= fy
                    d[e.b].dx += fx; d[e.b].dy += fy
                }
                for i in 0..<n {
                    // Gentle pull to the middle keeps loose dots near.
                    d[i].dx -= Double(p[i].x) * 0.05
                    d[i].dy -= Double(p[i].y) * 0.05
                    let len = max(sqrt(d[i].dx * d[i].dx + d[i].dy * d[i].dy), 0.01)
                    let step = min(len, temperature)
                    p[i].x += d[i].dx / len * step
                    p[i].y += d[i].dy / len * step
                }
                temperature = max(temperature * 0.97, 1)
            }
            return p
        }.value
        guard !Task.isCancelled else { return }
        self.edges = edges
        positions = result
        if !fitted, size.width > 0 {
            // Everything in view to start with.
            let xs = result.map { abs($0.x) }, ys = result.map { abs($0.y) }
            let need = max((xs.max() ?? 1) * 2 + 80, 1), needY = max((ys.max() ?? 1) * 2 + 160, 1)
            scale = min(max(min(size.width / need, size.height / needY), 0.2), 2)
            fitted = true
        }
    }
}
