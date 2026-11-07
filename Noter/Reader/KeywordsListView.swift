import SwiftUI

/// Slide-in panel listing the key words found in the book — people, events, places,
/// organizations, dates and key terms — each with the book page numbers it appears on.
/// Tap a key word (or a page number) to jump there; it blinks so it's easy to spot.
struct KeywordsListView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var index: KeywordIndex
    var onClose: () -> Void
    @State private var filter: KeywordKind?

    var body: some View {
        let _ = session.labelsVersion // refresh when page numbers improve
        let all = index.keywords
        let kinds = KeywordKind.allCases.filter { k in all.contains { $0.kind == k } }
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Key words")
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close key words")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Toggle(isOn: $index.markOnPages) {
                Label("Mark on pages", systemImage: "highlighter")
                    .font(.subheadline.weight(.medium))
            }
            .tint(.teal)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            if kinds.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("All", selected: filter == nil) { filter = nil }
                        ForEach(kinds) { k in
                            chip(k.title, selected: filter == k) { filter = k }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)
            }

            if all.isEmpty {
                Group {
                    if index.isScanning || session.ocrDone == 0 {
                        ProgressView("Finding key words…")
                    } else {
                        ContentUnavailableView(
                            "No key words yet",
                            systemImage: "key",
                            description: Text("Key words show up once the text of the book has been recognized."))
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(kinds.filter { filter == nil || $0 == filter }) { kind in
                            Label(kind.title, systemImage: kind.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                            ForEach(all.filter { $0.kind == kind }) { k in
                                KeywordRow(keyword: k, session: session)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .onAppear { index.start() }
    }

    private var subtitle: String {
        let found = "\(index.keywords.count) found"
        guard index.isScanning || session.ocrDone < session.pageCount else { return found }
        return "\(found) · scanned \(index.scannedPages) of \(session.pageCount) pages"
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct KeywordRow: View {
    let keyword: Keyword
    @ObservedObject var session: DocumentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let first = keyword.occurrences.first { session.open(first) }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(keyword.text)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Text("\(keyword.count)×")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Same page-number style as the highlights panel.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(keyword.firstPerPage.prefix(40), id: \.self) { occurrence in
                        Button {
                            session.open(occurrence)
                        } label: {
                            Text(session.label(for: occurrence.slot))
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
        .padding(12)
        .background(Color(.systemBackground).opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
