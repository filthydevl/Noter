import SwiftUI
import UIKit

/// The Notes panel: every highlight card (color, page, text, key word tags) with a note
/// field under it for your own notes and comments. Tap the highlight to jump to it.
struct NotesListView: View {
    @ObservedObject var session: DocumentSession
    var onClose: () -> Void
    @State private var onlyWithNotes = false
    /// The card whose note you just started typing in.
    @State private var editing: UUID?
    @State private var share: ShareItem?
    @AppStorage("noter.analysisTags") private var showAnalysis = true

    var body: some View {
        let all = session.groupedHighlights()
        let noted = all.filter { $0.noteText != nil }.count
        let items = onlyWithNotes ? all.filter { $0.noteText != nil } : all
        let keywords = session.keywordEntries(includingRemoved: true)
        let byKey = session.tagEntriesByKey()
        let _ = session.labelsVersion // refresh when page numbers improve
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notes")
                        .font(.title3.weight(.semibold))
                    Text("\(noted) note\(noted == 1 ? "" : "s") · \(all.count) highlight\(all.count == 1 ? "" : "s")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if noted > 0 {
                    Menu {
                        Button {
                            UIPasteboard.general.string = notesText(all)
                            session.showToast("Copied all notes")
                        } label: {
                            Label("Copy notes", systemImage: "doc.on.doc")
                        }
                        Button {
                            if let url = PDFExport.highlights(session, onlyWithNotes: true) {
                                share = ShareItem(url: url)
                            }
                        } label: {
                            Label("Export PDF", systemImage: "doc.richtext")
                        }
                    } label: {
                        PanelIcon(symbol: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share notes")
                }
                Button(action: onClose) { PanelIcon(symbol: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close notes")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            if !all.isEmpty {
                Picker("Show", selection: $onlyWithNotes) {
                    Text("All highlights").tag(false)
                    Text("With notes").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            if items.isEmpty {
                ContentUnavailableView(
                    all.isEmpty ? "No highlights yet" : "No notes yet",
                    systemImage: all.isEmpty ? "highlighter" : "text.bubble",
                    description: Text(all.isEmpty
                        ? "Highlight with your Apple Pencil, then write notes on your highlights here."
                        : "Write a note under any highlight in “All highlights”."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(items) { h in
                                VStack(spacing: 6) {
                                    if let word = session.term(of: h) {
                                        DefinitionArrow(word: Highlight.keywordDisplay(word.text))
                                    }
                                    HighlightRow(
                                        highlight: h,
                                        label: session.pageLabel(for: h),
                                        tags: session.tagKeys(of: h).compactMap { byKey[$0] },
                                        available: keywords.filter {
                                            !(h.isKeyword && $0.id == h.keywordKey)
                                                && !session.removedKeywords.contains($0.id)
                                        },
                                        open: { session.open(h) },
                                        toggleTag: { session.toggleTag($0, on: h.id) },
                                        delete: { session.removeHighlights([h.id]) },
                                        editNote: { session.setNote($0, on: h.id) },
                                        noteFocused: { if $0 { editing = h.id } },
                                        colorName: session.palette.name(h.color),
                                        showAnalysis: showAnalysis)
                                }
                                .id(h.id)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 20)
                    }
                    .defaultScrollAnchor(.bottom)
                    // You tapped a note: once the keyboard is up, bring that card into view.
                    .onChange(of: editing) { _, id in
                        guard let id else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .bottom) }
                            editing = nil
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .sheet(item: $share) { ShareSheet(url: $0.url) }
    }

    private func notesText(_ items: [Highlight]) -> String {
        items.compactMap { h -> String? in
            guard let note = h.noteText else { return nil }
            return "\(h.text)\n— \(session.pageLabel(for: h))\nNote: \(note)"
        }
        .joined(separator: "\n\n")
    }
}
