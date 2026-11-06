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

struct ReaderView: View {
    @ObservedObject var session: DocumentSession

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PDFReaderRepresentable(session: session)
                .ignoresSafeArea(edges: .bottom)
                .opacity(session.viewMode == .pdf ? 1 : 0)
                .allowsHitTesting(session.viewMode == .pdf)

            TranscriptRepresentable(session: session)
                .ignoresSafeArea(edges: .bottom)
                .opacity(session.viewMode == .transcript ? 1 : 0)
                .allowsHitTesting(session.viewMode == .transcript)

            if session.viewMode == .highlights {
                HighlightsListView(session: session)
            } else {
                SpeechControlView(speech: session.speech)
                    .padding(.top, 10)
                    .padding(.trailing, 14)
            }
        }
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

    private var layoutBinding: Binding<LayoutMode> {
        Binding(get: { session.info.layoutMode }, set: { session.setLayoutMode($0) })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $session.viewMode) {
                ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
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

            Button {
                session.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!session.canUndo)
            .accessibilityLabel("Undo")

            Button {
                session.toggleTool()
            } label: {
                Image(systemName: session.tool == .highlight ? "highlighter" : "eraser")
                    .foregroundStyle(session.tool == .highlight ? session.color.color : Color.red)
            }
            .accessibilityLabel(session.tool == .highlight ? "Highlighter (tap for eraser)" : "Eraser (tap for highlighter)")

            Menu {
                Picker("Highlight color", selection: $session.color) {
                    ForEach(HighlightColor.allCases) { c in
                        Text(c.name).tag(c)
                    }
                }
            } label: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(session.color.color)
            }
            .accessibilityLabel("Highlight color")

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
        }
    }
}
