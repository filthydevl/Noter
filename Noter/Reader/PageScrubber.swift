import SwiftUI

/// The slider at the bottom: where you are in the book (the same place in the PDF and
/// Text views). Slim while you read; while you drag it, the book's parts (its headings)
/// are marked along it and the part you're in is named above your finger.
struct PageScrubber: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var outline: OutlineIndex
    @State private var dragging: Double?
    @State private var lastSent: Int?

    private var count: Int { max(session.pageCount, 1) }

    var body: some View {
        let page = dragging.map { Int($0.rounded()) } ?? session.currentPage
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                GeometryReader { g in
                    let w = g.size.width
                    ZStack(alignment: .leading) {
                        // Track and progress.
                        Capsule().fill(Color.primary.opacity(0.14)).frame(height: 4)
                        Capsule().fill(Color.accentColor).frame(width: max(x(page, w), 4), height: 4)

                        // Parts, only while dragging.
                        if dragging != nil {
                            ForEach(outline.entries) { e in
                                Capsule()
                                    .fill(Color.primary.opacity(0.55))
                                    .frame(width: 2, height: 12)
                                    .offset(x: x(e.pdfIndex, w) - 1)
                            }
                            partLabels(w)
                        }

                        // Thumb.
                        Circle()
                            .fill(Color.accentColor)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                            .frame(width: dragging == nil ? 14 : 20, height: dragging == nil ? 14 : 20)
                            .offset(x: x(page, w) - (dragging == nil ? 7 : 10))
                    }
                    .frame(height: g.size.height)
                    .overlay(alignment: .topLeading) {
                        if dragging != nil { bubble(page, w) }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                let f = min(max(v.location.x / max(w, 1), 0), 1)
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
                .frame(height: 22)
                .animation(.easeOut(duration: 0.15), value: dragging == nil)

                Text(shortTitle(page))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
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
            // Fit the whole page on screen (PDF view).
            if session.viewMode == .pdf {
                Button {
                    session.pdfController?.fitPage()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 26)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fit page")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    // MARK: Pieces

    private func x(_ page: Int, _ width: CGFloat) -> CGFloat {
        guard count > 1 else { return 0 }
        return CGFloat(page) / CGFloat(count - 1) * width
    }

    /// Part names above their marks, skipping ones that would overlap.
    private func partLabels(_ w: CGFloat) -> some View {
        var shown: [OutlineIndex.Entry] = []
        var lastX = -CGFloat.infinity
        for e in outline.entries {
            let px = x(e.pdfIndex, w)
            if px - lastX >= 110 {
                shown.append(e)
                lastX = px
            }
        }
        return ForEach(shown) { e in
            Text(e.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: 104, alignment: .leading)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .fixedSize()
                .offset(x: min(x(e.pdfIndex, w), max(w - 110, 0)), y: -26)
        }
    }

    /// Above the thumb: the part you're in and the page.
    private func bubble(_ page: Int, _ w: CGFloat) -> some View {
        let part = outline.part(at: page)?.title
        return VStack(alignment: .leading, spacing: 2) {
            if let part {
                Text(part)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Text(longTitle(page))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .fixedSize()
        .offset(x: min(max(x(page, w) - 70, 0), max(w - 240, 0)), y: outline.entries.isEmpty ? -62 : -92)
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
