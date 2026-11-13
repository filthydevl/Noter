import SwiftUI

/// The slider up the left edge: where you are in the book (the same place in the PDF and
/// Text views), top to bottom. Small colored ticks show where your highlights are, in
/// their colors. While you drag it, the book's parts (its headings) are marked along it
/// and the part you're in is shown in full beside your finger. Fit page sits on top.
struct PageScrubber: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var outline: OutlineIndex
    @State private var dragging: Double?
    @State private var lastSent: Int?

    private var count: Int { max(session.pageCount, 1) }

    var body: some View {
        let page = dragging.map { Int($0.rounded()) } ?? session.currentPage
        VStack(spacing: 6) {
            // Fit the whole page on screen (PDF view).
            if session.viewMode == .pdf {
                Button {
                    session.pdfController?.fitPage()
                } label: {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18, height: 20)
                        .background(.thinMaterial, in: Rectangle())
                        .frame(width: 32, height: 30, alignment: .leading) // easy to tap, small to look at
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fit page")
            }

            track(page)
                .accessibilityElement()
                .accessibilityLabel("Page")
                .accessibilityValue(longTitle(page))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: session.goToPage(session.currentPage + 1)
                    case .decrement: session.goToPage(session.currentPage - 1)
                    @unknown default: break
                    }
                }

        }
        .frame(width: 32)
    }

    // MARK: Pieces

    private func track(_ page: Int) -> some View {
        GeometryReader { g in
            let h = g.size.height
            ZStack(alignment: .topLeading) {
                // Flush with the screen's left edge: a thin track (with a soft halo so it
                // shows on any page) and progress.
                Rectangle().fill(.thinMaterial).frame(width: 6)
                Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 2).offset(x: 2)
                Rectangle().fill(Color.accentColor).frame(width: 2, height: max(y(Double(page), h), 2))
                    .offset(x: 2)

                highlightTicks(h)

                // Parts, only while dragging.
                if dragging != nil {
                    ForEach(outline.entries) { e in
                        Rectangle()
                            .fill(Color.primary.opacity(0.6))
                            .frame(width: 10, height: 1.5)
                            .offset(y: y(e.position, h) - 1)
                    }
                }

                // Thumb: a bar against the edge (bigger while you drag it).
                let w: CGFloat = dragging == nil ? 6 : 10
                let tall: CGFloat = dragging == nil ? 22 : 34
                Rectangle()
                    .fill(Color.accentColor)
                    .overlay(Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 1)
                    .frame(width: w, height: tall)
                    .offset(y: min(max(y(Double(page), h) - tall / 2, 0), max(h - tall, 0)))
            }
            .frame(width: g.size.width, height: h)
            .overlay(alignment: .topLeading) {
                if dragging != nil {
                    partLabels(h)
                    bubble(page, h)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let f = min(max(v.location.y / max(h, 1), 0), 1)
                        let p = f * Double(count - 1)
                        dragging = p
                        let i = Int(p.rounded())
                        if i != lastSent {
                            lastSent = i
                            session.goToPage(i)
                        }
                    }
                    .onEnded { _ in
                        dragging = nil
                        lastSent = nil
                    })
        }
        .frame(width: 32) // a wide, invisible grab area around the hairline
        .animation(.easeOut(duration: 0.15), value: dragging == nil)
    }

    /// Down the track: where a page (or a spot within one) is.
    private func y(_ position: Double, _ height: CGFloat) -> CGFloat {
        guard count > 1 else { return 0 }
        return CGFloat(min(max(position / Double(count - 1), 0), 1)) * height
    }

    /// A small tick in each highlight's color on its page.
    private func highlightTicks(_ h: CGFloat) -> some View {
        var seen = Set<String>()
        var marks: [(page: Int, color: Color)] = []
        for hl in session.highlights.sorted(by: { $0.page < $1.page }) {
            let key = "\(hl.page)-\(hl.color.rawValue)"
            if seen.insert(key).inserted { marks.append((hl.page, hl.displayColor)) }
        }
        return Canvas { ctx, size in
            var perPage: [Int: Int] = [:]
            for m in marks {
                let n = perPage[m.page, default: 0]
                perPage[m.page] = n + 1
                // The first color across the track; more colors on that page beside it.
                let rect = n == 0
                    ? CGRect(x: 0, y: y(Double(m.page), size.height) - 1, width: 10, height: 2)
                    : CGRect(x: 11 + CGFloat(min(n - 1, 2)) * 3, y: y(Double(m.page), size.height) - 1,
                             width: 2, height: 2)
                ctx.fill(Path(rect), with: .color(m.color))
            }
        }
        .frame(height: h)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Part names to the right of their marks, skipping ones that would overlap.
    private func partLabels(_ h: CGFloat) -> some View {
        var shown: [OutlineIndex.Entry] = []
        var lastY = -CGFloat.infinity
        for e in outline.entries {
            let py = y(e.position, h)
            if py - lastY >= 26 {
                shown.append(e)
                lastY = py
            }
        }
        return ForEach(shown) { e in
            Text(e.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Rectangle())
                .fixedSize()
                .offset(x: 30, y: min(max(y(e.position, h) - 9, 0), max(h - 18, 0)))
                .allowsHitTesting(false)
        }
    }

    /// Beside the thumb: the whole name of the part you're in, and the page.
    private func bubble(_ page: Int, _ h: CGFloat) -> some View {
        let part = outline.part(at: page)?.title
        return VStack(alignment: .leading, spacing: 3) {
            if let part {
                Text(part)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(longTitle(page))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Rectangle())
        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.5)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .frame(width: 320, alignment: .leading) // long headings wrap, never cut off
        .offset(x: outline.entries.isEmpty ? 30 : 240, y: min(max(y(Double(page), h) - 30, 0), max(h - 90, 0)))
        .allowsHitTesting(false)
    }

    /// "p. 24"
    private func shortTitle(_ index: Int) -> String {
        let _ = session.labelsVersion
        let label = session.label(for: SlotKey(pdfIndex: index, half: 0))
        return label.hasPrefix("PDF page") ? "\(index + 1)/\(count)" : label
    }

    /// "p. 24 · PDF 13 of 200"
    private func longTitle(_ index: Int) -> String {
        let _ = session.labelsVersion
        let label = session.label(for: SlotKey(pdfIndex: index, half: 0))
        let pdf = "PDF \(index + 1) of \(count)"
        return label.hasPrefix("PDF page") ? pdf : "\(label) · \(pdf)"
    }
}
