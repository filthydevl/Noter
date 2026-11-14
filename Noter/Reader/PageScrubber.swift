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
    @State private var lastJump = Date.distantPast

    private var count: Int { max(session.pageCount, 1) }

    /// In the Text view the labels take its page colors (headings in the theme's heading
    /// color), so they never blend into the page.
    private var theme: ReaderTheme? { session.viewMode == .transcript ? session.textAppearance.theme : nil }
    private var titleColor: Color { theme.map { Color($0.heading) } ?? .primary }
    private var detailColor: Color { theme.map { Color($0.secondary) } ?? .secondary }

    @ViewBuilder
    private func labelBackground(border: Color?) -> some View {
        if let theme {
            Rectangle().fill(Color(theme.background).opacity(0.97))
                .overlay(Rectangle().strokeBorder(Color(theme.heading).opacity(0.55)))
        } else {
            Rectangle().fill(.regularMaterial)
                .overlay(Rectangle().strokeBorder(border ?? .clear))
        }
    }

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
                        .frame(width: 22, height: 22)
                        .background(.thinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                        .padding(.leading, 3)
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
                            .fill(theme.map { Color($0.heading) } ?? Color.primary.opacity(0.6))
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
            // Fingers only: the Apple Pencil writes on the page, it never moves the
            // slider (and a stroke that starts over the slider still reaches the page).
            .allowsHitTesting(false)
            .background {
                FingerTrack(onChange: { location, size in
                    let f = min(max(location.y / max(size.height, 1), 0), 1)
                    let p = f * Double(count - 1)
                    dragging = p
                    let i = Int(p.rounded())
                    // At most ~12 jumps a second while you drag: each one draws a
                    // page, and a fast drag through a long book kept the device so
                    // busy the read-aloud voice smeared.
                    if i != lastSent, Date().timeIntervalSince(lastJump) > 0.08 {
                        lastSent = i
                        lastJump = Date()
                        session.goToPage(i)
                    }
                }, onEnd: {
                    // Land exactly where you let go.
                    if let d = dragging {
                        let i = Int(d.rounded())
                        if i != lastSent { session.goToPage(i) }
                    }
                    dragging = nil
                    lastSent = nil
                })
                .allowsHitTesting(false)
            }
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
                    ? CGRect(x: 0, y: y(Double(m.page), size.height) - 2, width: 14, height: 4)
                    : CGRect(x: 15 + CGFloat(min(n - 1, 2)) * 5, y: y(Double(m.page), size.height) - 2,
                             width: 4, height: 4)
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
                .font(.caption2.weight(.semibold))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background { labelBackground(border: nil) }
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
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(longTitle(page))
                .font(.caption.monospacedDigit())
                .foregroundStyle(detailColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { labelBackground(border: Color.accentColor.opacity(0.5)) }
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
