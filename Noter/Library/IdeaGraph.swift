import SwiftUI
import simd

/// "View Notes" map: the reading's highlights as dots floating in 3D, joined where
/// they're connected, slowly turning (like Obsidian's 3D graph), drawn flat and quiet
/// on the app's own background.
///
/// - Highlights gather by color round a neutral hub named after the color; the hubs
///   hang off the book in the middle. Only the highlights are in color.
/// - Strong lines: one idea across highlights in a row in the same color, or a
///   passage linked to a circled word.
/// - With "Link related ideas": highlights that share a tag (a tag hub) or several
///   uncommon words (faint lines).
///
/// Drag to turn it, pinch to zoom, tap a sphere to bring it to the middle and light up
/// what it's connected to; tap empty space to let go.
struct IdeaGraph: View {
    let highlights: [Highlight]
    let title: String
    let linkTags: Bool
    @Binding var selected: UUID?

    @State private var model = GraphModel()
    @State private var yaw = 0.0
    @State private var pitch = -0.32
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var dragBase: SIMD2<Double>?
    @State private var spin = true
    @State private var spinFrom = Date()
    @State private var focus: Int?
    @State private var counts = SIMD2<Int>(0, 0)

    /// Radians a second while it turns by itself.
    private let spinRate = 0.06

    private var spinning: Bool { spin && dragBase == nil && focus == nil }

    var body: some View {
        GeometryReader { g in
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                Canvas { ctx, size in
                    let turn = spinning ? spinRate * timeline.date.timeIntervalSince(spinFrom) : 0
                    model.draw(in: &ctx, size: size, yaw: yaw + turn, pitch: pitch,
                               zoom: Double(zoom * pinch), focus: focus)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { v in
                        if dragBase == nil {
                            bakeSpin()
                            dragBase = SIMD2(yaw, pitch)
                        }
                        guard let base = dragBase else { return }
                        yaw = base.x + Double(v.translation.width) * 0.008
                        pitch = min(max(base.y - Double(v.translation.height) * 0.008, -1.45), 1.45)
                    }
                    .onEnded { _ in
                        dragBase = nil
                        spinFrom = Date()
                    })
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { v, s, _ in s = v.magnification }
                    .onEnded { v in zoom = min(max(zoom * v.magnification, 0.35), 5) })
            .simultaneousGesture(
                SpatialTapGesture().onEnded { t in tap(at: t.location) })
            .overlay(alignment: .topLeading) { controls.padding(14) }
            .overlay(alignment: .topTrailing) { legend.padding(14) }
            .overlay {
                if highlights.isEmpty {
                    Text("Nothing matches these filters")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: rebuildKey) { await rebuild() }
            .onChange(of: selected) { _, id in
                // Closed from outside (the card): let go here too.
                if id == nil, let f = focus, model.isHighlight(f) { setFocus(nil) }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var rebuildKey: [String] {
        highlights.map(\.id.uuidString) + [linkTags ? "tags" : "", title]
    }

    // MARK: Interaction

    /// Folds the turning so far into `yaw`, so it carries on from where it is.
    private func bakeSpin() {
        if spinning { yaw += spinRate * Date().timeIntervalSince(spinFrom) }
        spinFrom = Date()
    }

    private func setFocus(_ i: Int?) {
        bakeSpin()
        focus = i
        spinFrom = Date()
        selected = i.flatMap { model.highlightID($0) }
    }

    private func tap(at p: CGPoint) {
        setFocus(model.node(at: p))
    }

    private func rebuild() async {
        let hs = highlights
        let tags = linkTags
        let book = title
        let built = await Task.detached(priority: .userInitiated) {
            GraphModel.Blueprint.make(hs, title: book, related: tags)
        }.value
        guard !Task.isCancelled else { return }
        let keep = focus.flatMap { model.key(of: $0) }
        model.load(built, highlights: hs)
        counts = SIMD2(model.highlightCount, model.linkCount)
        focus = keep.flatMap { model.index(of: $0) }
        if focus == nil, selected != nil { selected = nil }
    }

    // MARK: Overlays

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                bakeSpin()
                spin.toggle()
                spinFrom = Date()
            } label: {
                Image(systemName: spin ? "pause" : "rotate.3d")
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel(spin ? "Stop turning" : "Turn")
            Button {
                withAnimation(.snappy) { zoom = 1 }
                setFocus(nil)
                pitch = -0.32
            } label: {
                Image(systemName: "scope")
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Recenter")
            Text("\(counts.x) highlights · \(counts.y) links")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(2)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle().strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.2).frame(width: 10, height: 10)
                Text("Color group")
            }
            HStack(spacing: 7) {
                Rectangle().frame(width: 16, height: 1.5)
                Text("One idea / linked")
            }
            if linkTags {
                HStack(spacing: 7) {
                    Rectangle().frame(width: 16, height: 1).opacity(0.4)
                    Text("Related (tag, words)")
                }
            }
            HStack(spacing: 7) {
                Circle().fill(Color.secondary).frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: 1).padding(-2.5))
                    .frame(width: 10, height: 10)
                Text("Has a note")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

// MARK: - The graph and its simulation

/// The nodes, links and their positions in 3D, settled by a force simulation that runs
/// a step each frame (connected things pull together, everything pushes apart).
final class GraphModel {
    enum Kind: Sendable {
        case highlight(Int)
        case hub
        case book
        case tag

        var isTag: Bool {
            if case .tag = self { return true }
            return false
        }
    }

    enum Style: Sendable {
        case idea, hub, related
    }

    struct Link: Sendable {
        let a: Int, b: Int
        let style: Style
        let distance: Double
        let strength: Double
    }

    /// What the graph is, worked out off the main thread.
    struct Blueprint: Sendable {
        struct Node: Sendable {
            let key: String
            let kind: Kind
            let label: String
            /// The color it's drawn in: a highlight (its shade), a color, or none.
            let highlight: Int?
            let colorRaw: String?
            let size: Double
            let noted: Bool
        }
        var nodes: [Node] = []
        var links: [Link] = []

        static func make(_ hs: [Highlight], title: String, related: Bool) -> Blueprint {
            var bp = Blueprint()
            var degree = [Int](repeating: 0, count: hs.count)
            var links: [Link] = []
            func link(_ a: Int, _ b: Int, _ style: Style) {
                switch style {
                case .idea: links.append(Link(a: a, b: b, style: style, distance: 22, strength: 0.9))
                case .hub: links.append(Link(a: a, b: b, style: style, distance: 46, strength: 0.32))
                case .related: links.append(Link(a: a, b: b, style: style, distance: 60, strength: 0.08))
                }
                if a < hs.count { degree[a] += 1 }
                if b < hs.count { degree[b] += 1 }
            }

            // One idea across highlights in a row in the same color.
            for i in hs.indices.dropFirst() where hs[i].color == hs[i - 1].color && !hs[i].isTerm && !hs[i - 1].isTerm {
                link(i - 1, i, .idea)
            }
            // Passages linked to a circled word.
            let index = Dictionary(hs.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
            for (i, h) in hs.enumerated() {
                if let t = h.termID, let j = index[t], j != i { link(j, i, .idea) }
            }

            var extra: [Node] = []
            var hubLinks: [(Int, Int, Style)] = []   // indices into hs, or hs.count + extra index
            let base = hs.count

            // The book in the middle, a hub per color.
            extra.append(Node(key: "book", kind: .book, label: title, highlight: nil, colorRaw: nil, size: 7, noted: false))
            var hubOf: [String: Int] = [:]
            var members: [String: Int] = [:]
            for h in hs { members[h.color.rawValue, default: 0] += 1 }
            for (i, h) in hs.enumerated() {
                let raw = h.color.rawValue
                if hubOf[raw] == nil {
                    hubOf[raw] = base + extra.count
                    let count = Double(members[raw] ?? 1)
                    extra.append(Node(key: "c:\(raw)", kind: .hub, label: h.color.name, highlight: nil,
                                      colorRaw: raw, size: 6 + sqrt(count) * 0.9, noted: false))
                    hubLinks.append((base, hubOf[raw]!, .hub))
                }
                hubLinks.append((hubOf[raw]!, i, .hub))
            }

            if related {
                // A tag in common (key words, analysis tags): a small hub for the tag.
                var byTag: [String: [Int]] = [:]
                for (i, h) in hs.enumerated() {
                    for t in h.tagKeys { byTag[t, default: []].append(i) }
                    if h.isKeyword { byTag[h.keywordKey, default: []].append(i) }
                }
                for (tag, idx) in byTag.sorted(by: { $0.key < $1.key }) where idx.count > 1 {
                    let t = base + extra.count
                    extra.append(Node(key: "t:\(tag)", kind: .tag, label: "#\(tag)", highlight: nil, colorRaw: nil,
                                      size: 3.5 + sqrt(Double(idx.count)) * 0.5, noted: false))
                    for i in idx { hubLinks.append((t, i, .related)) }
                }
                // Several uncommon words in common: probably the same idea.
                if hs.count <= 700 {
                    let words = hs.map { significantWords($0.text) }
                    var best = [[(Int, Int)]](repeating: [], count: hs.count)
                    for i in hs.indices where words[i].count >= 2 {
                        for j in (i + 1)..<hs.count where words[j].count >= 2 {
                            let shared = words[i].intersection(words[j]).count
                            if shared >= 2 {
                                best[i].append((j, shared))
                                best[j].append((i, shared))
                            }
                        }
                    }
                    var seen = Set<Int>()
                    for i in hs.indices {
                        for (j, _) in best[i].sorted(by: { $0.1 > $1.1 }).prefix(3) {
                            let key = min(i, j) * hs.count + max(i, j)
                            if seen.insert(key).inserted { link(min(i, j), max(i, j), .related) }
                        }
                    }
                }
            }
            for (a, b, s) in hubLinks { link(a, b, s) }

            var made: [Node] = []
            for (i, h) in hs.enumerated() {
                let words = h.text.split(separator: " ")
                let label = words.prefix(6).joined(separator: " ") + (words.count > 6 ? "…" : "")
                let noted = h.noteText != nil
                made.append(Node(key: h.id.uuidString, kind: .highlight(i), label: label, highlight: i,
                                 colorRaw: h.color.rawValue,
                                 size: 3.6 + min(Double(degree[i]), 8) * 0.3 + (noted ? 0.6 : 0),
                                 noted: noted))
            }
            bp.nodes = made + extra
            bp.links = links
            return bp
        }

        private static let stop: Set<String> = [
            "about", "after", "again", "against", "because", "before", "being", "between", "could", "during",
            "every", "first", "their", "there", "these", "those", "through", "under", "until", "where",
            "which", "while", "would", "other", "should", "still", "since", "within", "without", "among",
            "many", "much", "more", "most", "such", "they", "them", "then", "than", "that", "this", "with",
            "were", "what", "when", "will", "into", "only", "also", "very", "over", "upon", "each", "some",
        ]

        static func significantWords(_ text: String) -> Set<String> {
            var out = Set<String>()
            for w in text.lowercased().split(whereSeparator: { !$0.isLetter }) where w.count >= 5 {
                let s = String(w)
                if !stop.contains(s) { out.insert(s.hasSuffix("s") ? String(s.dropLast()) : s) }
            }
            return out
        }
    }

    /// A highlight's own color; hubs, tags and the book are neutral (nil).
    typealias Palette = Color?

    private struct Node {
        let key: String
        let kind: Kind
        let label: String
        let size: Double
        let noted: Bool
        let palette: Palette
        var p: SIMD3<Double>
        var v = SIMD3<Double>.zero
        var charge: Double
    }

    private var nodes: [Node] = []
    private var links: [Link] = []
    private var neighbors: [Set<Int>] = []
    private var linkCountOf: [Double] = []
    private var highlightIDs: [UUID?] = []
    private var alpha = 1.0
    private var radius = 120.0
    private var center = SIMD3<Double>.zero
    /// Where each node was drawn last frame (for taps).
    private var drawn: [(index: Int, point: CGPoint, r: CGFloat, z: Double)] = []
    private(set) var highlightCount = 0
    private(set) var linkCount = 0

    func isHighlight(_ i: Int) -> Bool {
        guard nodes.indices.contains(i), case .highlight = nodes[i].kind else { return false }
        return true
    }

    func highlightID(_ i: Int) -> UUID? { highlightIDs.indices.contains(i) ? highlightIDs[i] : nil }
    func key(of i: Int) -> String? { nodes.indices.contains(i) ? nodes[i].key : nil }
    func index(of key: String) -> Int? { nodes.firstIndex { $0.key == key } }

    /// Takes a new graph, keeping where the nodes that were already there are.
    func load(_ bp: Blueprint, highlights hs: [Highlight]) {
        let old = Dictionary(nodes.map { ($0.key, $0.p) }, uniquingKeysWith: { a, _ in a })
        let first = nodes.isEmpty
        var made: [Node] = []
        let total = Double(max(bp.nodes.count, 1))
        for (i, n) in bp.nodes.enumerated() {
            let palette: Palette = n.highlight.map { Color(uiColor: hs[$0].uiColor) }
            // New ones start on a ball round the middle (spread evenly).
            let fi = Double(i)
            let y: Double = 1 - 2 * (fi + 0.5) / total
            let r: Double = (max(1 - y * y, 0)).squareRoot()
            let a: Double = fi * 2.399963
            let spread: Double = 60 + Double(i % 7) * 12
            let start = SIMD3<Double>(r * cos(a), y, r * sin(a)) * spread
            let charge: Double
            switch n.kind {
            case .book: charge = -260
            case .hub: charge = -180
            case .tag: charge = -70
            case .highlight: charge = -45
            }
            let p: SIMD3<Double> = old[n.key] ?? start
            made.append(Node(key: n.key, kind: n.kind, label: n.label, size: n.size, noted: n.noted,
                             palette: palette, p: p, charge: charge))
        }
        nodes = made
        links = bp.links
        neighbors = Array(repeating: [], count: nodes.count)
        linkCountOf = Array(repeating: 0, count: nodes.count)
        for l in links {
            neighbors[l.a].insert(l.b)
            neighbors[l.b].insert(l.a)
            linkCountOf[l.a] += 1
            linkCountOf[l.b] += 1
        }
        highlightIDs = nodes.map { n in
            if case .highlight(let i) = n.kind { return hs[i].id }
            return nil
        }
        highlightCount = hs.count
        linkCount = links.filter { $0.style != .hub }.count
        alpha = first ? 1 : max(alpha, 0.5)
        drawn = []
    }

    // MARK: Simulation (velocity Verlet, like d3-force in 3D)

    private func tick() {
        guard alpha > 0.003, !nodes.isEmpty else { return }
        alpha += (0 - alpha) * 0.018
        let n = nodes.count
        // Everything pushes apart.
        for i in 0..<n {
            for j in (i + 1)..<n {
                var d = nodes[j].p - nodes[i].p
                var l2 = simd_length_squared(d)
                if l2 > 160_000 { continue }
                if l2 < 0.01 {
                    let jx: Double = Double((i * 7) % 5) - 2
                    let jz: Double = Double((j * 3) % 5) - 2
                    d = SIMD3<Double>(jx * 0.1, 0.1, jz * 0.1)
                    l2 = simd_length_squared(d)
                }
                l2 = max(l2, 25)
                nodes[i].v += d * (nodes[j].charge * alpha / l2)
                nodes[j].v -= d * (nodes[i].charge * alpha / l2)
            }
        }
        // Connected things pull together.
        for l in links {
            var d = (nodes[l.b].p + nodes[l.b].v) - (nodes[l.a].p + nodes[l.a].v)
            let len = max(simd_length(d), 0.001)
            let k = (len - l.distance) / len * alpha * l.strength
            d *= k
            let ca = linkCountOf[l.a], cb = linkCountOf[l.b]
            let bias = ca / max(ca + cb, 1)
            nodes[l.b].v -= d * bias
            nodes[l.a].v += d * (1 - bias)
        }
        var far = 40.0
        for i in 0..<n {
            nodes[i].v -= nodes[i].p * (0.012 * alpha)   // a gentle pull to the middle
            nodes[i].v *= 0.6
            nodes[i].p += nodes[i].v
            far = max(far, simd_length(nodes[i].p))
        }
        radius += (far - radius) * 0.08
    }

    // MARK: Drawing

    func draw(in ctx: inout GraphicsContext, size: CGSize, yaw: Double, pitch: Double, zoom: Double, focus: Int?) {
        tick()
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        guard !nodes.isEmpty else { drawn = []; return }

        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        func rotate(_ c: SIMD3<Double>) -> SIMD3<Double> {
            let x1: Double = c.x * cy + c.z * sy
            let z1: Double = -c.x * sy + c.z * cy
            let y2: Double = c.y * cp - z1 * sp
            let z2: Double = c.y * sp + z1 * cp
            return SIMD3<Double>(x1, y2, z2)
        }

        // The camera follows the tapped node to the middle.
        let target = focus.map { nodes.indices.contains($0) ? nodes[$0].p : .zero } ?? .zero
        center += (target - center) * 0.08

        let R = max(radius, 60)
        let fov = R * 3
        let scale = Double(min(size.width, size.height)) * 0.42 / R * zoom
        var screen = [CGPoint](repeating: .zero, count: nodes.count)
        var depth = [Double](repeating: 0, count: nodes.count)
        var persp = [Double](repeating: 1, count: nodes.count)
        for (i, n) in nodes.enumerated() {
            let r = rotate(n.p - center)
            let s: Double = fov / max(fov + r.z, fov * 0.15)
            let k: Double = s * scale
            screen[i] = CGPoint(x: mid.x + CGFloat(r.x * k), y: mid.y + CGFloat(r.y * k))
            depth[i] = r.z
            persp[i] = s
        }
        // Farther back: fainter (depth without effects).
        func fade(_ z: Double) -> Double { 1 - 0.5 * min(max((z + R) / (2 * R), 0), 1) }
        var lit: Set<Int>?
        if let f = focus {
            var set: Set<Int> = [f]
            if neighbors.indices.contains(f) { set.formUnion(neighbors[f]) }
            lit = set
        }
        let sizeScale: Double = min(max(zoom.squareRoot(), 0.75), 2)
        let ink = Color.primary
        let paper = Color(.systemGroupedBackground)

        // Links: hairlines; one idea in the highlight's color, the rest neutral.
        for l in links {
            let touches = focus == l.a || focus == l.b
            var a = fade((depth[l.a] + depth[l.b]) / 2)
            let color: Color
            let base: Double
            switch l.style {
            case .idea:
                color = nodes[l.b].palette ?? ink
                a *= 0.7
                base = 1.3
            case .hub:
                color = ink
                a *= 0.14
                base = 0.7
            case .related:
                color = ink
                a *= 0.18
                base = 0.7
            }
            if focus != nil { a = touches ? min(a * 2.5, 0.9) : a * 0.25 }
            guard a > 0.015 else { continue }
            var path = Path()
            path.move(to: screen[l.a])
            path.addLine(to: screen[l.b])
            let dash: [CGFloat] = l.style == .related ? [2, 3] : []
            let width = CGFloat(base * (touches ? 1.4 : 1))
            ctx.stroke(path, with: .color(color.opacity(a)), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        }

        // Dots, back to front.
        var order = Array(nodes.indices)
        order.sort { depth[$0] > depth[$1] }
        var hits: [(index: Int, point: CGPoint, r: CGFloat, z: Double)] = []
        var labels: [(Int, CGPoint, CGFloat, Double)] = []
        for i in order {
            let n = nodes[i]
            let p = screen[i]
            let r = CGFloat(n.size * persp[i] * sizeScale)
            let pad: CGFloat = r * 2
            guard p.x > -pad, p.y > -pad, p.x < size.width + pad, p.y < size.height + pad else { continue }
            var dim = fade(depth[i])
            if let lit, !lit.contains(i) { dim *= 0.25 }
            var c = ctx
            c.opacity = dim
            let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            switch n.kind {
            case .highlight:
                // Flat, in its color, with a thin edge of the background so dots
                // in front read separately.
                c.fill(dot, with: .color(n.palette ?? ink))
                c.stroke(dot, with: .color(paper), lineWidth: 1)
                if n.noted {
                    let o = r + 2.5
                    c.stroke(Path(ellipseIn: CGRect(x: p.x - o, y: p.y - o, width: o * 2, height: o * 2)),
                             with: .color(ink.opacity(0.55)), lineWidth: 1)
                }
            case .hub, .tag:
                // Neutral: a ring on the background.
                c.fill(dot, with: .color(paper))
                c.stroke(dot, with: .color(ink.opacity(n.kind.isTag ? 0.35 : 0.6)), lineWidth: n.kind.isTag ? 1 : 1.5)
            case .book:
                c.fill(dot, with: .color(ink.opacity(0.85)))
            }
            if focus == i {
                let o = r + 4
                c.stroke(Path(ellipseIn: CGRect(x: p.x - o, y: p.y - o, width: o * 2, height: o * 2)),
                         with: .color(.accentColor), lineWidth: 1.5)
            }
            hits.append((i, p, r, depth[i]))
            let near = persp[i] * zoom > 1.5
            if isHub(n) || focus == i || (lit?.contains(i) ?? false) || near {
                labels.append((i, p, r, dim))
            }
        }

        // Names: hubs always, highlights when near or lit.
        for (i, p, r, dim) in labels.prefix(50) {
            let n = nodes[i]
            let hub = isHub(n)
            let font: Font = hub ? .caption.weight(.semibold) : .caption2
            let style: Color = hub ? ink : Color.secondary
            let text = Text(n.label).font(font).foregroundStyle(style.opacity(max(dim, 0.4)))
            let below: CGFloat = hub ? 10 : 8
            ctx.draw(text, at: CGPoint(x: p.x, y: p.y + r + below), anchor: .center)
        }
        drawn = hits
    }

    private func isHub(_ n: Node) -> Bool {
        switch n.kind {
        case .hub, .book: true
        default: false
        }
    }

    /// The sphere under a tap (the front one if they overlap).
    func node(at p: CGPoint) -> Int? {
        var best: (Int, Double)?
        for h in drawn {
            let d = hypot(h.point.x - p.x, h.point.y - p.y)
            guard d < max(h.r + 12, 22) else { continue }
            let score = Double(d) + h.z * 0.05
            if score < (best?.1 ?? .infinity) { best = (h.index, score) }
        }
        return best?.0
    }
}
