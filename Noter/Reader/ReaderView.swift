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
    case highlights, notes, keywords, questions, search
}

struct ReaderView: View {
    @ObservedObject var session: DocumentSession
    @State private var panel: SidePanel?
    @State private var savedPDF: ShareItem?

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
        .overlay(alignment: .leading) {
            // The player sits right above the tool rail.
            VStack(alignment: .leading, spacing: 12) {
                SpeechControlView(speech: session.speech) { session.showReadingPosition() }
                ToolRail(session: session, scribble: session.scribble, panel: $panel)
            }
            .padding(.leading, 14)
        }
        .overlay(alignment: .bottom) {
            if session.penMode == .scribble && session.viewMode != .transcript {
                ScribbleToolbar(session: session, settings: session.scribble)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if showScrubber {
                PageScrubber(session: session)
                    .padding(.horizontal, 80)
                    .padding(.trailing, panel == nil ? 0 : 372)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.25), value: session.penMode)
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
        .background(PencilInteractionHost { session.pencilButton() })
        .overlay(alignment: .bottom) {
            if let toast = session.toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 84)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.toast)
        .sheet(item: $savedPDF) { ShareSheet(url: $0.url) }
        .navigationTitle(session.info.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
    }

    @ViewBuilder
    private func sidePanel(_ panel: SidePanel) -> some View {
        switch panel {
        case .highlights:
            HighlightsListView(session: session) { self.panel = nil }
        case .notes:
            NotesListView(session: session) { self.panel = nil }
        case .keywords:
            KeywordsListView(session: session) { self.panel = nil }
        case .questions:
            QuestionsListView(session: session, index: session.questions) { self.panel = nil }
        case .search:
            SearchListView(session: session, search: session.search) { self.panel = nil }
        }
    }

    /// The page slider, except while the scribble toolbar is there.
    private var showScrubber: Bool {
        !(session.penMode == .scribble && session.viewMode != .transcript) && session.pageCount > 1
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
            } else if session.ocrUpgradeLeft > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Refining text · \(session.ocrUpgradeLeft) left")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Improving recognized text, \(session.ocrUpgradeLeft) pages left")
            }

            Button {
                panel = panel == .search ? nil : .search
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Search")

            Menu {
                Button {
                    session.savePDF(includeScribbles: false) { savedPDF = ShareItem(url: $0) }
                } label: {
                    Label("PDF with highlights", systemImage: "highlighter")
                }
                Button {
                    session.savePDF(includeScribbles: true) { savedPDF = ShareItem(url: $0) }
                } label: {
                    Label("PDF with highlights + scribbles", systemImage: "pencil.tip")
                }
                Text("Highlights stay real PDF highlights (notes become their comments). Scribbles are baked onto the pages only if you choose so.")
            } label: {
                if session.isSavingPDF {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .disabled(session.isSavingPDF)
            .accessibilityLabel("Save PDF")

            Menu {
                Picker("Page layout", selection: layoutBinding) {
                    ForEach(LayoutMode.allCases) { Text($0.title).tag($0) }
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
    @ObservedObject var scribble: ScribbleSettings
    @Binding var panel: SidePanel?
    @State private var showColors = false
    @State private var showTextOptions = false

    private var scribbling: Bool { session.penMode == .scribble }
    private var penColor: Color { scribbling ? scribble.color.color : session.color.color }

    var body: some View {
        VStack(spacing: 4) {
            // Pen: tap to switch highlighter ↔ scribble pen (or back from the eraser).
            railButton(scribbling ? "pencil.tip" : "highlighter",
                       label: scribbling ? "Scribble pen (tap for highlighter)" : "Highlighter (tap for scribble pen)",
                       selected: session.tool == .pen, tint: penColor) {
                session.togglePen()
            }
            .overlay(alignment: .topTrailing) {
                if session.scribbleHint {
                    Image(systemName: "exclamationmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .orange)
                        .font(.system(size: 17, weight: .bold))
                        .offset(x: 5, y: -5)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Scribble is on")
                }
            }
            .animation(.spring(duration: 0.3), value: session.scribbleHint)

            railButton("eraser", label: scribbling ? "Ink eraser" : "Highlight eraser",
                       selected: session.tool == .erase) {
                session.tool = .erase
            }

            Button {
                showColors.toggle()
            } label: {
                Circle()
                    .fill(penColor)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(scribbling ? "Ink color" : "Highlight color")
            .popover(isPresented: $showColors, arrowEdge: .leading) {
                Group {
                    if scribbling {
                        HStack(spacing: 14) {
                            ForEach(InkColor.allCases) { c in
                                swatch(c.color, selected: c == scribble.color, name: c.name) {
                                    scribble.color = c
                                }
                            }
                        }
                    } else {
                        HStack(spacing: 14) {
                            ForEach(HighlightColor.allCases) { c in
                                swatch(c.color, selected: c == session.color, name: c.name) {
                                    session.color = c
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .presentationCompactAdaptation(.popover)
            }

            divider

            if scribbling {
                railButton("arrow.uturn.backward", label: "Undo") { session.inkUndo.undo() }
            } else {
                railButton("arrow.uturn.backward", label: "Undo") { session.undo() }
                    .disabled(!session.canUndo)
                    .opacity(session.canUndo ? 1 : 0.35)
            }

            divider

            railButton("text.quote", label: "Highlights", selected: panel == .highlights) {
                panel = panel == .highlights ? nil : .highlights
            }
            railButton("text.bubble", label: "Notes", selected: panel == .notes) {
                panel = panel == .notes ? nil : .notes
            }
            railButton("key", label: "Key words", selected: panel == .keywords) {
                panel = panel == .keywords ? nil : .keywords
            }
            railButton("questionmark.bubble", label: "Questions", selected: panel == .questions, tint: .purple) {
                panel = panel == .questions ? nil : .questions
            }

            // Text view customization (theme, font, size, spacing, margins…).
            if session.viewMode == .transcript {
                divider
                railButton("textformat.size", label: "Reading options", selected: showTextOptions) {
                    showTextOptions = true
                }
                .popover(isPresented: $showTextOptions, arrowEdge: .leading) {
                    TextOptionsView(session: session)
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }

    private func swatch(_ color: Color, selected: Bool, name: String, pick: @escaping () -> Void) -> some View {
        Button {
            pick()
            session.tool = .pen
            showColors = false
        } label: {
            Circle()
                .fill(color)
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.7 : 0.12), lineWidth: selected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
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
