import SwiftUI

/// Slide-in panel with your key words — every single word or short phrase you've
/// highlighted — in their highlight color, with the book pages you highlighted them on
/// and the highlights you've tagged with them. Tap a page or a highlight to jump there.
struct KeywordsListView: View {
    @ObservedObject var session: DocumentSession
    var onClose: () -> Void
    @State private var share: ShareItem?
    @AppStorage("noter.analysisTags") private var showAnalysis = true

    var body: some View {
        let _ = session.labelsVersion // refresh when page numbers improve
        let entries = session.keywordEntries()
        let analysis = session.analysisEntries(onlyUsed: true)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Key words")
                        .font(.title3.weight(.semibold))
                    Text("\(entries.count) key word\(entries.count == 1 ? "" : "s")"
                         + (analysis.isEmpty ? "" : " · \(analysis.count) analysis tag\(analysis.count == 1 ? "" : "s")"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Group {
                    Menu {
                        Toggle(isOn: $showAnalysis) {
                            Label("Analysis tags in tag menus", systemImage: "text.magnifyingglass")
                        }
                        if !entries.isEmpty {
                            Button {
                                if let url = PDFExport.keywords(session) { share = ShareItem(url: url) }
                            } label: {
                                Label("Export PDF", systemImage: "doc.richtext")
                            }
                        }
                        if !session.removedKeywords.isEmpty {
                            Button {
                                session.restoreRemovedKeywords()
                            } label: {
                                Label("Restore \(session.removedKeywords.count) removed", systemImage: "arrow.uturn.backward")
                            }
                        }
                    } label: {
                        PanelIcon(symbol: "ellipsis")
                    }
                    .accessibilityLabel("Key words options")
                }
                Button(action: onClose) { PanelIcon(symbol: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close key words")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            if entries.isEmpty && analysis.isEmpty {
                ContentUnavailableView(
                    "No key words yet",
                    systemImage: "key",
                    description: Text("Highlight a single word or a short phrase — a name, an event, a term — or circle it with the highlighter, and it becomes a key word. Then tag your other highlights with it."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        // Cause, effect, premise… you've tagged highlights with.
                        if !analysis.isEmpty {
                            sectionTitle("Analysis")
                            ForEach(analysis) { k in KeywordRow(keyword: k, session: session) }
                            if !entries.isEmpty { sectionTitle("Key words") }
                        }
                        ForEach(entries) { k in
                            KeywordRow(keyword: k, session: session)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        session.removeKeyword(k.id)
                                    } label: {
                                        Label("Remove from Key words", systemImage: "minus.circle")
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
        .sheet(item: $share) { ShareSheet(url: $0.url) }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct KeywordRow: View {
    let keyword: KeywordEntry
    @ObservedObject var session: DocumentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Button {
                    if let first = keyword.mentions.first ?? keyword.linked.first { session.open(first) }
                } label: {
                    TagChip(keyword: keyword)
                        .font(.body)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                Text("\(keyword.linked.count) \(keyword.isAnalysis ? "tagged" : "linked")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                // Takes it off this list only; its highlights stay.
                if !keyword.isAnalysis {
                Button {
                    session.removeKeyword(keyword.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove key word")
                }
            }

            // Where you highlighted it — same page-number style as the highlights panel.
            if !keyword.mentions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(keyword.mentions) { h in
                        Button {
                            session.open(h)
                        } label: {
                            HStack(spacing: 3) {
                                Text(session.pageLabel(for: h))
                                if h.isTerm {
                                    Image(systemName: "circle")
                                        .accessibilityLabel("circled")
                                }
                            }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            }

            // Highlights tagged with it.
            ForEach(keyword.linked) { h in
                Button {
                    session.open(h)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(h.displayColor)
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(h.text)
                                .font(.system(.footnote, design: .serif))
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                            Text(session.pageLabel(for: h))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(.systemBackground).opacity(0.75), in: Rectangle())
    }
}
