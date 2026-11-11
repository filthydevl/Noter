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
            session?.reopen()
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
    case highlights, notes, keywords, questions, search, colors
}

struct ReaderView: View {
    @ObservedObject var session: DocumentSession
    @State private var panel: SidePanel?
    @State private var savedPDF: ShareItem?
    @State private var viewWidth: CGFloat = 0

    var body: some View {
        ZStack {
            // Under the top bar too: only its buttons float over the page.
            PDFReaderRepresentable(session: session)
                .ignoresSafeArea(edges: [.top, .bottom])
                .opacity(session.viewMode == .transcript ? 0 : 1)
                .allowsHitTesting(session.viewMode != .transcript)

            TranscriptRepresentable(session: session)
                .ignoresSafeArea(edges: [.top, .bottom])
                .opacity(session.viewMode == .transcript ? 1 : 0)
                .allowsHitTesting(session.viewMode == .transcript)
        }
        // Landscape with a panel open: the page moves over to the left, beside the panel
        // and the rail, instead of sitting under them.
        .padding(.trailing, pushesPageLeft ? 376 + Self.railWidth + 8 : 0)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .overlay(alignment: .trailing) {
            // At the very edge of the screen, below Undo (scrolls if the screen is short).
            ViewThatFits(in: .vertical) {
                rail
                ScrollView(.vertical, showsIndicators: false) { rail }
            }
            .padding(.top, 122)
            .padding(.bottom, scribbleBar ? 76 : 10)
            .padding(.trailing, railTrailing)
        }
        // Above the rail, so nothing ever covers the player.
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 10) {
                SpeechControlView(speech: session.speech) { session.showReadingPosition() }
                // Under the player, Undo lined up with the tool rail below it.
                UndoRedoControls(session: session)
                    .padding(.trailing, (Self.railWidth - 46) / 2)
            }
            .padding(.top, 10)
            .padding(.trailing, railTrailing)
        }
        .overlay(alignment: .bottom) {
            if scribbleBar {
                ScribbleToolbar(session: session, settings: session.scribble)
                    .padding(.horizontal, 50) // clear of the page slider and the rail
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .leading) {
            if session.pageCount > 1 {
                // Up the very left edge of the screen.
                PageScrubber(session: session, outline: session.outline)
                    .padding(.leading, 4)
                    .padding(.top, 8)
                    .padding(.bottom, scribbleBar ? 76 : 16)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            // Just circled a word: underline its definition (as many lines as you like),
            // then ✓ saves it.
            if let word = session.pendingTermText {
                let parts = session.definitionParts.count
                HStack(spacing: 10) {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(HighlightColor.maroon.color)
                    Text(parts == 0 ? "Underline the definition of “\(word)”"
                         : "Definition of “\(word)” · \(parts) part\(parts == 1 ? "" : "s") — keep going or tap ✓")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Button {
                        session.confirmDefinition()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(HighlightColor.maroon.color, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Save definition")
                    Button {
                        session.cancelPendingTerm()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(Color.primary.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(parts == 0 ? "Skip the definition" : "Discard the definition")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(HighlightColor.maroon.color.opacity(0.5)))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.28), value: panel)
        // Jumping to a highlight centers it in the part of the page you can see.
        .onChange(of: panel) { _, p in
            session.panelOpen = p != nil
            updateCoveredRight()
        }
        // In portrait an open panel would cover the spot you jump to: it closes.
        .onChange(of: session.closePanelSignal) { _, _ in panel = nil }
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { widthChanged(g.size.width) }
                    .onChange(of: g.size.width) { _, w in widthChanged(w) }
            }
        }
        .animation(.snappy(duration: 0.25), value: session.pendingTerm)
        .animation(.snappy(duration: 0.25), value: session.penMode)
        .overlay(alignment: .trailing) {
            if let panel {
                sidePanel(panel)
                    .frame(width: 360)
                    .avoidingKeyboard()
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
        .toolbarBackground(.hidden, for: .navigationBar)
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
        case .colors:
            ColorsListView(session: session, palette: session.palette) { self.panel = nil }
        }
    }

    static let railWidth: CGFloat = 56

    /// Wide (landscape) with a panel open: the page sits to the left of it.
    private var pushesPageLeft: Bool { panel != nil && viewWidth >= 1140 }

    private func widthChanged(_ w: CGFloat) {
        // The page area's own width doesn't count (it shrinks beside a panel).
        guard w > 0 else { return }
        viewWidth = w
        session.narrowLayout = w < 1140
        updateCoveredRight()
    }

    /// How much of the page's right side is under the rail / a panel, for centering a
    /// highlight you jump to.
    private func updateCoveredRight() {
        let covered: CGFloat
        if panel == nil {
            covered = Self.railWidth + 8
        } else if pushesPageLeft {
            covered = 8 // the panel and rail are beside the page, not over it
        } else {
            covered = 372 + Self.railWidth + 12
        }
        session.pdfController?.coveredRight = covered
    }

    /// The tool rail's distance from the right edge: at the edge, or beside an open panel.
    private var railTrailing: CGFloat { panel == nil ? 4 : 376 }

    private var scribbleBar: Bool { session.penMode == .scribble && session.viewMode != .transcript }

    private var rail: some View {
        ToolRail(session: session, scribble: session.scribble, palette: session.palette, panel: $panel)
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

            Menu {
                Button {
                    session.savePDF(baked: true) { savedPDF = ShareItem(url: $0) }
                } label: {
                    Label("Save PDF — highlights + scribbles", systemImage: "square.and.arrow.down")
                }
                Button {
                    session.savePDF(baked: false) { savedPDF = ShareItem(url: $0) }
                } label: {
                    Label("Editable highlights only", systemImage: "highlighter")
                }
                Text("Save PDF prints your highlights and scribbles onto the pages. “Editable” keeps highlights as PDF highlights other apps can change, without scribbles. Notes become sticky notes.")
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

/// Undo under the player: your last highlight change, or your last ink / shape change
/// while scribbling. Redo shows up beside it only after an undo, and goes away by
/// itself a few seconds later, once there's nothing left to redo, or when you change
/// something new.
private struct UndoRedoControls: View {
    @ObservedObject var session: DocumentSession
    /// Bumped when the ink undo manager changes (it isn't observable).
    @State private var inkTick = 0
    @State private var redoOffered = false
    @State private var hideTask: Task<Void, Never>?

    private var scribbling: Bool { session.penMode == .scribble && session.viewMode != .transcript }

    var body: some View {
        let _ = inkTick
        let canUndo = scribbling ? session.inkUndo.canUndo : session.canUndo
        let canRedo = scribbling ? session.inkUndo.canRedo : session.canRedo
        let showRedo = redoOffered && canRedo
        HStack(spacing: 10) {
            // Appears to the left, so Undo never moves under your finger.
            button("arrow.uturn.forward", "Redo", enabled: true) {
                if scribbling { session.inkUndo.redo() } else { session.redo() }
                offerRedo()
            }
            .opacity(showRedo ? 1 : 0)
            .scaleEffect(showRedo ? 1 : 0.5)
            .allowsHitTesting(showRedo)
            .accessibilityHidden(!showRedo)
            button("arrow.uturn.backward", "Undo", enabled: canUndo) {
                if scribbling { session.inkUndo.undo() } else { session.undo() }
                offerRedo()
            }
        }
        .animation(.snappy(duration: 0.22), value: showRedo)
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { inkChanged($0) }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { inkChanged($0) }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { inkChanged($0) }
        .onChange(of: session.penMode) { _, _ in redoOffered = false }
    }

    private func inkChanged(_ note: Notification) {
        guard (note.object as? UndoManager) === session.inkUndo else { return }
        inkTick &+= 1
    }

    private func offerRedo() {
        redoOffered = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            redoOffered = false
        }
    }

    private func button(_ symbol: String, _ label: String, enabled: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 46, height: 46)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(label)
    }
}

/// Floating vertical toolbar on the right: search, highlighter, eraser, the colors, the
/// color wheel (modes, names, adding colors), auto color switch, highlights, notes, key
/// words, questions (undo is in the bottom-right corner).
private struct ToolRail: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var scribble: ScribbleSettings
    @ObservedObject var palette: ColorPalette
    @Binding var panel: SidePanel?
    @State private var showColors = false
    @State private var showTextOptions = false

    private var scribbling: Bool { session.penMode == .scribble }
    private var penColor: Color { scribbling ? scribble.color.color : session.color.color }

    var body: some View {
        VStack(spacing: 4) {
            // Find a word or sentence in the book.
            railButton("magnifyingglass", label: "Search", selected: panel == .search) {
                panel = panel == .search ? nil : .search
            }

            divider

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

            divider

            // The colors, right on the rail: tap one to use it.
            if scribbling {
                ForEach(InkColor.allCases.prefix(5)) { c in
                    railSwatch(c.color, selected: c == scribble.color, name: c.name) { scribble.color = c }
                }
            } else {
                // (More than 7 colors: the rest are under the color wheel.)
                ForEach(palette.colors.prefix(7)) { c in
                    railSwatch(c.color, selected: c == session.color, name: palette.name(c) ?? c.name) {
                        session.color = c
                    }
                }
            }

            // Color wheel: color modes, names, and adding / removing colors.
            Button {
                showColors.toggle()
            } label: {
                Circle()
                    .fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .mint, .cyan, .blue, .purple, .pink, .red],
                                          center: .center))
                    .overlay(Circle().fill(.white.opacity(0.9)).frame(width: 7, height: 7))
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(scribbling ? "Ink color" : "Highlight color")
            .popover(isPresented: $showColors, arrowEdge: .trailing) {
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
                        highlightColors
                    }
                }
                .padding(16)
                .presentationCompactAdaptation(.popover)
            }

            // Auto-switch: a new color after every highlight (each idea stands out).
            if !scribbling {
                railButton("arrow.triangle.2.circlepath", label: palette.autoSwitch
                           ? "Auto color switch on (tap for manual)" : "Auto color switch off (tap to turn on)",
                           selected: palette.autoSwitch) {
                    palette.autoSwitch.toggle()
                    session.showToast(palette.autoSwitch ? "Auto color switch: a new color for every highlight"
                                      : "Manual colors")
                }
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
                .popover(isPresented: $showTextOptions, arrowEdge: .trailing) {
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

    /// Highlight colors with your names for them, the auto / manual switch, and the way
    /// to name and add colors.
    private var highlightColors: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Color mode", selection: $palette.autoSwitch) {
                Text("Auto switch").tag(true)
                Text("Manual").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            Text(palette.autoSwitch ? "A new color after every highlight."
                 : "Same color = same idea; each new highlight in it gets a new shade.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 290, alignment: .leading)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 8), count: 5), spacing: 10) {
                ForEach(palette.colors) { c in
                    VStack(spacing: 4) {
                        swatch(c.color, selected: c == session.color, name: palette.name(c) ?? c.name) {
                            session.color = c
                        }
                        Text(palette.name(c) ?? " ")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 58)
                    }
                }
            }
            Button {
                showColors = false
                panel = .colors
            } label: {
                Label("Name & add colors…", systemImage: "paintpalette")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    /// A color on the rail.
    private func railSwatch(_ color: Color, selected: Bool, name: String, pick: @escaping () -> Void) -> some View {
        Button {
            pick()
            session.tool = .pen
        } label: {
            Circle()
                .fill(color)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.75 : 0.12),
                                               lineWidth: selected ? 2.5 : 1))
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? color.opacity(0.6) : .clear, lineWidth: 2))
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
