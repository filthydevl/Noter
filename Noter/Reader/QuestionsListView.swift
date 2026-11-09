import SwiftUI

/// The questions highlighter: every question in the book — genuine and rhetorical —
/// with its book page. "Mark on pages" highlights them in the PDF and text views; tap
/// one to jump there (it blinks).
struct QuestionsListView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var index: QuestionIndex
    var onClose: () -> Void
    @State private var filter: QuestionKind?
    @State private var share: ShareItem?

    var body: some View {
        let _ = session.labelsVersion // refresh when page numbers improve
        let shown = index.questions.filter { filter == nil || $0.kind == filter }
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Questions")
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !index.questions.isEmpty || !index.removed.isEmpty {
                    Menu {
                        if !index.questions.isEmpty {
                            Button {
                                if let url = PDFExport.questions(session, shown) { share = ShareItem(url: url) }
                            } label: {
                                Label("Export PDF", systemImage: "doc.richtext")
                            }
                        }
                        if !index.removed.isEmpty {
                            Button {
                                index.restoreRemoved()
                            } label: {
                                Label("Restore \(index.removed.count) removed", systemImage: "arrow.uturn.backward")
                            }
                        }
                    } label: {
                        PanelIcon(symbol: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export questions")
                }
                Button(action: onClose) { PanelIcon(symbol: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close questions")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Toggle(isOn: $index.markOnPages) {
                Label("Mark on pages", systemImage: "highlighter")
                    .font(.subheadline.weight(.medium))
            }
            .tint(.purple)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            HStack(spacing: 6) {
                chip("All", count: index.questions.count, selected: filter == nil) { filter = nil }
                ForEach(QuestionKind.allCases) { k in
                    chip(k.pluralTitle, count: index.questions.filter { $0.kind == k }.count,
                         selected: filter == k) { filter = k }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if shown.isEmpty {
                Group {
                    if index.isScanning || session.ocrDone == 0 {
                        ProgressView("Finding questions…")
                    } else {
                        ContentUnavailableView(
                            "No questions found",
                            systemImage: "questionmark.bubble",
                            description: Text("Questions show up here once the pages they're on have been recognized."))
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(shown) { q in
                            HStack(alignment: .top, spacing: 6) {
                                Button {
                                    session.open(q.location)
                                } label: {
                                    QuestionRow(question: q, label: session.label(for: q.location.slot))
                                }
                                .buttonStyle(.plain)
                                RemoveCellButton(label: "Remove question") { index.remove(q) }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    index.remove(q)
                                } label: {
                                    Label("Remove from Questions", systemImage: "minus.circle")
                                }
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
        .sheet(item: $share) { ShareSheet(url: $0.url) }
    }

    private var subtitle: String {
        let found = "\(index.questions.count) found"
        guard index.isScanning || session.ocrDone < session.pageCount else { return found }
        return "\(found) · scanned \(index.scannedPages) of \(session.pageCount) pages"
    }

    private func chip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(title) \(count)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.purple : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct QuestionRow: View {
    let question: Question
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(question.kind.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(question.kind == .rhetorical ? Color.purple : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background((question.kind == .rhetorical ? Color.purple : Color.primary).opacity(0.1),
                                in: Capsule())
            }
            Text(question.text)
                .font(.system(.callout, design: .serif))
                .foregroundStyle(.primary)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color(.systemBackground).opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}
