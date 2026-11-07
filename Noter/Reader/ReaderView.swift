import SwiftUI

/// Opens a document from the library and keeps its session alive while it's on screen.
struct ReaderScreen: View {
    let docID: UUID
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var holder = SessionHolder()

    var body: some View {
        Group {
            if let session = holder.session {
                ReaderView(session: session)
            } else if holder.failed {
                ContentUnavailableView("Couldn't open this PDF", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        .onAppear { holder.open(docID) }
        .onDisappear {
            holder.session?.close()
            library.reload()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { holder.session?.saveAll() }
        }
    }
}

@MainActor
final class SessionHolder: ObservableObject {
    @Published private(set) var session: DocumentSession?
    @Published private(set) var failed = false

    func open(_ id: UUID) {
        guard session == nil else {
            session?.ocr.start()
            return
        }
        if let info = Storage.load(DocumentInfo.self, from: Storage.infoURL(id)),
           let s = DocumentSession(info: info) {
            session = s
        } else {
            failed = true
        }
    }
}

/// The slide-in panel on the right.
enum SidePanel {
    case highlights, keywords, questions
}

struct ReaderView: View {
    @ObservedObject var session: DocumentSession
    @State private var panel: SidePanel?

    var body: some View {
        ZStack {
            PDFReaderRepresentable(session: session)
                .ignoresSafeArea(edges: .bottom)
                .opacity(session.viewMode == .transcript ? 0 : 1)
                .allowsHitTesting(session.viewMode != .transcript)

            TranscriptRepresentable(session: session)
                .ignoresSafeArea(edges: .bottom)
                .opacity(session.viewMode == .transcript ? 1 : 0)
                .allowsHitTesting(session.viewMode == .transcript)
        }
        .overlay(alignment: .topTrailing) {
            SpeechControlView(speech: session.speech)
                .padding(.top, 10)
                .padding(.trailing, 14)
        }
        .overlay(alignment: .leading) {
            ToolRail(session: session, panel: $panel)
                .padding(.leading, 14)
        }
        .overlay(alignment: .trailing) {
            if let panel {
                sidePanel(panel)
                    .frame(width: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
                    .padding(12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.28), value: panel)
        .background(PencilInteractionHost { session.toggleTool() })
        .overlay(alignment: .bottom) {
            if let toast = session.toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 28)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.toast)
        .navigationTitle(session.info.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
    }

    @ViewBuilder
    private func sidePanel(_ panel: SidePanel) -> some View {
        switch panel {
        case .highlights:
            HighlightsListView(session: session) { self.panel = nil }
        case .keywords:
            KeywordsListView(session: session) { self.panel = nil }
        case .questions:
            QuestionsListView(session: session, index: session.questions) { self.panel = nil }
        }
    }

    private var layoutBinding: Binding<LayoutMode> {
        Binding(get: { session.info.layoutMode }, set: { session.setLayoutMode($0) })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $session.viewMode) {
                Text(ViewMode.pdf.title).tag(ViewMode.pdf)
                Text(ViewMode.transcript.title).tag(ViewMode.transcript)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if session.ocrDone < session.pageCount {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading \(session.ocrDone)/\(session.pageCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Recognizing text, \(session.ocrDone) of \(session.pageCount) pages")
            }

            Menu {
                Picker("Page layout", selection: layoutBinding) {
                    ForEach(LayoutMode.allCases) { Text($0.title).tag($0) }
                }
                Section("Text size") {
                    Button {
                        session.transcriptFontSize = min(session.transcriptFontSize + 2, 40)
                    } label: {
                        Label("Larger text", systemImage: "textformat.size.larger")
                    }
                    Button {
                        session.transcriptFontSize = max(session.transcriptFontSize - 2, 13)
                    } label: {
                        Label("Smaller text", systemImage: "textformat.size.smaller")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More options")
        }
    }
}

/// Floating vertical toolbar on the left: highlighter, eraser, color, undo, highlights,
/// key words, questions.
private struct ToolRail: View {
    @ObservedObject var session: DocumentSession
    @Binding var panel: SidePanel?
    @State private var showColors = false

    var body: some View {
        VStack(spacing: 4) {
            railButton("highlighter", label: "Highlighter",
                       selected: session.tool == .highlight, tint: session.color.color) {
                session.tool = .highlight
            }
            railButton("eraser", label: "Eraser", selected: session.tool == .erase) {
                session.tool = .erase
            }

            Button {
                showColors.toggle()
            } label: {
                Circle()
                    .fill(session.color.color)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Highlight color")
            .popover(isPresented: $showColors, arrowEdge: .leading) {
                HStack(spacing: 14) {
                    ForEach(HighlightColor.allCases) { c in
                        Button {
                            session.color = c
                            session.tool = .highlight
                            showColors = false
                        } label: {
                            Circle()
                                .fill(c.color)
                                .frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(c == session.color ? 0.7 : 0.12),
                                                               lineWidth: c == session.color ? 2.5 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.name)
                    }
                }
                .padding(16)
                .presentationCompactAdaptation(.popover)
            }

            divider

            railButton("arrow.uturn.backward", label: "Undo") { session.undo() }
                .disabled(!session.canUndo)
                .opacity(session.canUndo ? 1 : 0.35)

            divider

            railButton("text.quote", label: "Highlights", selected: panel == .highlights) {
                panel = panel == .highlights ? nil : .highlights
            }
            railButton("key", label: "Key words", selected: panel == .keywords) {
                panel = panel == .keywords ? nil : .keywords
            }
            railButton("questionmark.bubble", label: "Questions", selected: panel == .questions, tint: .purple) {
                panel = panel == .questions ? nil : .questions
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 26, height: 1).padding(.vertical, 2)
    }

    private func railButton(_ symbol: String, label: String, selected: Bool = false, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(selected ? (tint ?? Color.accentColor) : Color.primary)
                .frame(width: 44, height: 44)
                .background(selected ? Color.primary.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
