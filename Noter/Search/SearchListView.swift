import SwiftUI

/// Search panel: type a word or a sentence; every place it appears in the recognized
/// book, with its page. Tap one to jump there (it blinks).
struct SearchListView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var search: BookSearch
    var onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let _ = session.labelsVersion // refresh when page numbers improve
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Search")
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { PanelIcon(symbol: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close search")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Word or sentence", text: $search.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .accessibilityLabel("Search text")
                if !search.query.isEmpty {
                    Button {
                        search.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.07), in: Rectangle())
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if search.hits.isEmpty {
                Group {
                    if search.isSearching {
                        ProgressView("Searching…")
                    } else if search.query.trimmingCharacters(in: .whitespaces).count < 2 {
                        ContentUnavailableView(
                            "Search the book",
                            systemImage: "magnifyingglass",
                            description: Text("Finds whole words and sentences, ignoring upper and lower case."))
                    } else {
                        ContentUnavailableView.search(text: search.query)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(search.hits) { hit in
                            Button {
                                session.open(hit.location)
                            } label: {
                                SearchRow(hit: hit, label: session.label(for: hit.location.slot))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .onAppear {
            focused = search.query.isEmpty
            if !search.query.isEmpty, search.hits.isEmpty, !search.isSearching { search.run() }
        }
    }

    private var subtitle: String {
        let q = search.query.trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        if q.count >= 2 {
            let n = search.hits.count
            parts.append(search.limitReached ? "\(n)+ matches" : "\(n) match\(n == 1 ? "" : "es")")
        }
        if session.ocrDone < session.pageCount {
            parts.append("\(session.ocrDone) of \(session.pageCount) pages recognized so far")
        } else if search.isSearching {
            parts.append("searching \(search.searchedPages) of \(session.ocrDone) pages")
        }
        return parts.isEmpty ? "Whole words · any case" : parts.joined(separator: " · ")
    }
}

private struct SearchRow: View {
    let hit: SearchHit
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            (Text(hit.before).foregroundStyle(.secondary)
                + Text(hit.match).bold().foregroundStyle(Color.accentColor)
                + Text(hit.after).foregroundStyle(.secondary))
                .font(.system(.callout, design: .serif))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: Rectangle())
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(hit.before)\(hit.match)\(hit.after)")
    }
}
