import SwiftUI
import simd

/// "View Notes" map: the reading's highlights as glowing spheres floating in 3D,
/// joined where they're connected, and slowly turning (like Obsidian's 3D graph).
///
/// - Each highlight color has a hub (a big sphere named after the color), with its
///   highlights gathered round it, and the hubs hang off the book in the middle.
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
    private let spinRate = 0.11

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
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .environment(\.colorScheme, .dark)
            .task(id: rebuildKey) { await rebuild() }
            .onChange(of: selected) { _, id in
                // Closed from outside (the card): let go here too.
                if id == nil, let f = focus, model.isHighlight(f) { setFocus(nil) }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .background(Color.black)
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
                Image(systemName: spin ? "pause.fill" : "rotate.3d")
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(spin ? "Stop turning" : "Turn")
            Button {
                withAnimation(.snappy) { zoom = 1 }
                setFocus(nil)
                pitch = -0.32
            } label: {
                Image(systemName: "scope")
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Recenter")
            Text("\(counts.x) highlights · \(counts.y) links")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 6)
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white.opacity(0.9))
        .buttonStyle(.plain)
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle().fill(.white.opacity(0.85)).frame(width: 11, height: 11)
                Text("Color hub")
            }
            HStack(spacing: 7) {
                Rectangle().frame(width: 18, height: 2)
                Text("One idea / linked")
            }
            if linkTags {
                HStack(spacing: 7) {
                    Rectangle().frame(width: 18, height: 1).opacity(0.45)
                    Text("Related (tag, words)")
                }
            }
            HStack(spacing: 7) {
                Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.2).frame(width: 10, height: 10)
                Text("Has a note")
            }
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.75))
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            extra.append(Node(key: "book", kind: .book, label: title, highlight: nil, colorRaw: nil, size: 15, noted: false))
            var hubOf: [String: Int] = [:]
            var members: [String: Int] = [:]
            for h in hs { members[h.color.rawValue, default: 0] += 1 }
            for (i, h) in hs.enumerated() {
                let raw = h.color.rawValue
                if hubOf[raw] == nil {
                    hubOf[raw] = base + extra.count
                    let count = Double(members[raw] ?? 1)
                    extra.append(Node(key: "c:\(raw)", kind: .hub, label: h.color.name, highlight: nil,
                                      colorRaw: raw, size: 9 + sqrt(count) * 1.6, noted: false))
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
                                      size: 5 + sqrt(Double(idx.count)), noted: false))
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
                                 size: 4.2 + min(Double(degree[i]), 8) * 0.45 + (noted ? 1.2 : 0),
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

    struct Palette {
        let base: Color, light: Color, dark: Color, glow: Color

        init(_ ui: UIColor) {
            let c = ui.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if !c.getHue(&h, saturation: &s, brightness: &b, alpha: &a) { s = 0; b = 0.9 }
            base = Color(hue: h, saturation: s, brightness: max(b, 0.78))
            light = Color(hue: h, saturation: s * 0.3, brightness: 1)
            dark = Color(hue: h, saturation: min(s * 1.1, 1), brightness: max(b, 0.78) * 0.38)
            glow = Color(hue: h, saturation: min(s * 1.15, 1), brightness: 1)
        }

        static let book = Palette(UIColor(white: 0.95, alpha: 1))
        static let tag = Palette(UIColor(red: 0.62, green: 0.58, blue: 1, alpha: 1))
    }

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
    private let stars: [(SIMD3<Double>, Double)] = GraphModel.makeStars()

    /// Spread evenly over a far sphere, brightness varied.
    private static func makeStars() -> [(SIMD3<Double>, Double)] {
        var out: [(SIMD3<Double>, Double)] = []
        for i in 0..<140 {
            let fi = Double(i)
            let y: Double = 1 - 2 * (fi + 0.5) / 140
            let r: Double = (1 - y * y).squareRoot()
            let a: Double = fi * 2.399963
            let glow: Double = 0.15 + 0.5 * Double((i * 37) % 11) / 10
            out.append((SIMD3<Double>(r * cos(a), y, r * sin(a)), glow))
        }
        return out
    }

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
        var palettes: [String: Palette] = [:]
        var made: [Node] = []
        let total = Double(max(bp.nodes.count, 1))
        for (i, n) in bp.nodes.enumerated() {
            let palette: Palette
            if let h = n.highlight {
                palette = Palette(hs[h].uiColor)
            } else if let raw = n.colorRaw, let c = HighlightColor(rawValue: raw) {
                palette = palettes[raw] ?? Palette(c.uiColor(shade: nil))
                palettes[raw] = palette
            } else if case .tag = n.kind {
                palette = .tag
            } else {
                palette = .book
            }
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

        // Deep space.
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(colors: [Color(red: 0.10, green: 0.09, blue: 0.20), Color(red: 0.03, green: 0.03, blue: 0.07),
                              Color(red: 0.01, green: 0.01, blue: 0.02)]),
            center: CGPoint(x: mid.x, y: mid.y * 0.85), startRadius: 0, endRadius: max(size.width, size.height) * 0.75))

        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        func rotate(_ c: SIMD3<Double>) -> SIMD3<Double> {
            let x1: Double = c.x * cy + c.z * sy
            let z1: Double = -c.x * sy + c.z * cy
            let y2: Double = c.y * cp - z1 * sp
            let z2: Double = c.y * sp + z1 * cp
            return SIMD3<Double>(x1, y2, z2)
        }

        // Stars, turning slower than the graph (they're far away).
        let reach = Double(max(size.width, size.height)) * 0.75
        for (dir, glow) in stars {
            let r = rotate(dir)
            guard r.z < 0.2 else { continue }
            let pt = CGPoint(x: mid.x + CGFloat(r.x * reach), y: mid.y + CGFloat(r.y * reach))
            let s = CGFloat(0.6 + glow * 1.2)
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - s / 2, y: pt.y - s / 2, width: s, height: s)),
                     with: .color(.white.opacity(glow * 0.7)))
        }
        guard !nodes.isEmpty else { drawn = []; return }

        // The camera follows the tapped node to the middle.
        let target = focus.map { nodes.indices.contains($0) ? nodes[$0].p : .zero } ?? .zero
        center += (target - center) * 0.08

        let R = max(radius, 60)
        let fov = R * 2.6
        let scale = Double(min(size.width, size.height)) * 0.43 / R * zoom
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
        func fog(_ z: Double) -> Double { 1 - 0.62 * min(max((z + R) / (2 * R), 0), 1) }
        var lit: Set<Int>?
        if let f = focus {
            var set: Set<Int> = [f]
            if neighbors.indices.contains(f) { set.formUnion(neighbors[f]) }
            lit = set
        }
        let sizeScale: Double = min(max(zoom.squareRoot(), 0.7), 2.2)

        // Links, far ones fainter.
        for l in links {
            let touches = focus == l.a || focus == l.b
            var a = fog((depth[l.a] + depth[l.b]) / 2)
            switch l.style {
            case .idea: a *= 0.85
            case .hub: a *= 0.32
            case .related: a *= 0.3
            }
            if focus != nil { a *= touches ? 1.6 : 0.12 }
            guard a > 0.02 else { continue }
            var path = Path()
            path.move(to: screen[l.a])
            path.addLine(to: screen[l.b])
            let base: Double = l.style == .idea ? 1.8 : 1.0
            let width = CGFloat(base * min(persp[l.a], 2) * (touches ? 1.5 : 1))
            let shown: Double = min(a, 1)
            let fade = Gradient(colors: [nodes[l.a].palette.glow.opacity(shown), nodes[l.b].palette.glow.opacity(shown)])
            let dash: [CGFloat] = l.style == .related ? [3, 4] : []
            let stroke = StrokeStyle(lineWidth: width, lineCap: .round, dash: dash)
            ctx.stroke(path, with: .linearGradient(fade, startPoint: screen[l.a], endPoint: screen[l.b]), style: stroke)
        }

        // Spheres, back to front.
        var order = Array(nodes.indices)
        order.sort { depth[$0] > depth[$1] }
        var hits: [(index: Int, point: CGPoint, r: CGFloat, z: Double)] = []
        var labels: [(Int, CGPoint, CGFloat, Double)] = []
        for i in order {
            let n = nodes[i]
            let p = screen[i]
            let r = CGFloat(n.size * persp[i] * sizeScale)
            let pad: CGFloat = r * 3
            guard p.x > -pad, p.y > -pad, p.x < size.width + pad, p.y < size.height + pad else { continue }
            var dim = fog(depth[i])
            if let lit, !lit.contains(i) { dim *= 0.18 }
            var c = ctx
            c.opacity = dim
            // Glow.
            let g = r * (focus == i ? 4.2 : 3)
            let glowStrength: Double = isHub(n) ? 0.5 : 0.38
            let halo = Gradient(colors: [n.palette.glow.opacity(glowStrength), n.palette.glow.opacity(0)])
            let haloRect = CGRect(x: p.x - g, y: p.y - g, width: g * 2, height: g * 2)
            c.fill(Path(ellipseIn: haloRect), with: .radialGradient(halo, center: p, startRadius: r * 0.6, endRadius: g))
            // The sphere: lit from the upper left.
            let ball = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            let shading = Gradient(stops: [
                Gradient.Stop(color: n.palette.light, location: 0),
                Gradient.Stop(color: n.palette.base, location: 0.45),
                Gradient.Stop(color: n.palette.dark, location: 1),
            ])
            let lightAt = CGPoint(x: p.x - r * 0.38, y: p.y - r * 0.42)
            c.fill(ball, with: .radialGradient(shading, center: lightAt, startRadius: 0, endRadius: r * 1.55))
            if isHub(n) {
                let o = r * 1.45
                c.stroke(Path(ellipseIn: CGRect(x: p.x - o, y: p.y - o, width: o * 2, height: o * 2)),
                         with: .color(n.palette.glow.opacity(0.35)), lineWidth: 1)
            }
            if n.noted || focus == i {
                let o = r + 2.5
                c.stroke(Path(ellipseIn: CGRect(x: p.x - o, y: p.y - o, width: o * 2, height: o * 2)),
                         with: .color(.white.opacity(focus == i ? 0.95 : 0.6)), lineWidth: focus == i ? 2 : 1.1)
            }
            hits.append((i, p, r, depth[i]))
            let near = persp[i] * zoom > 1.45
            if isHub(n) || focus == i || (lit?.contains(i) ?? false) || near {
                labels.append((i, p, r, dim))
            }
        }

        // Names: hubs always, highlights when near or lit.
        for (i, p, r, dim) in labels.prefix(60) {
            let n = nodes[i]
            let hub = isHub(n)
            let strength: Double = (hub ? 0.92 : 0.78) * max(dim, 0.35)
            let font: Font = hub ? .caption.weight(.bold) : .caption2.weight(.medium)
            let text = Text(n.label).font(font).foregroundStyle(Color.white.opacity(strength))
            var c = ctx
            c.addFilter(.shadow(color: .black.opacity(0.9), radius: 3))
            let below: CGFloat = hub ? 11 : 9
            c.draw(text, at: CGPoint(x: p.x, y: p.y + r + below), anchor: .center)
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
