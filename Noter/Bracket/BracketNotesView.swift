import SwiftUI
import UIKit

/// The Bracket Notes panel: the page you're on, transposed sentence by sentence into
/// your indented note style. Highlights (without a note) are what you're focusing on:
/// the notes are redone around them and their lines take the highlight's color.
struct BracketNotesView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var notes: BracketNotes
    var onClose: () -> Void
    @AppStorage("noter.bracketScope") private var scopeRaw = BracketNotes.Scope.page.rawValue
    @State private var showSetup = false
    /// Text size of the notes (pinch, or Larger / Smaller in the menu).
    @AppStorage("noter.bracketZoom") private var zoom = 1.0
    @GestureState private var pinch = 1.0

    private var scope: BracketNotes.Scope { BracketNotes.Scope(rawValue: scopeRaw) ?? .page }

    private struct Trigger: Equatable {
        var page: Int
        var scope: String
        var focus: String
        var hasKey: Bool
        var apple: Bool
        var ocrDone: Int
    }

    var body: some View {
        let page = session.currentPage
        let _ = session.labelsVersion
        let entry = notes.entry(page: page, scope: scope)
        let working = notes.isWorking(page: page, scope: scope)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bracket Notes")
                        .font(.title3.weight(.semibold))
                    Text(subtitle(page: page, entry: entry))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Menu {
                    Button {
                        UIPasteboard.general.string = entry?.text ?? ""
                        session.showToast("Copied this page's bracket notes")
                    } label: {
                        Label("Copy notes", systemImage: "doc.on.doc")
                    }
                    .disabled((entry?.text ?? "").isEmpty)
                    ControlGroup {
                        Button {
                            zoom = Self.clampZoom(zoom / 1.15)
                        } label: {
                            Label("Smaller", systemImage: "textformat.size.smaller")
                        }
                        Button {
                            zoom = Self.clampZoom(zoom * 1.15)
                        } label: {
                            Label("Larger", systemImage: "textformat.size.larger")
                        }
                    }
                    Button {
                        notes.refresh(page: page, scope: scope, force: true)
                    } label: {
                        Label("Redo this page", systemImage: "arrow.clockwise")
                    }
                    Button {
                        showSetup = true
                    } label: {
                        Label(notes.hasKey ? "Claude settings…" : "Set up Claude…", systemImage: "gearshape")
                    }
                } label: {
                    PanelIcon(symbol: "ellipsis")
                }
                .accessibilityLabel("Bracket Notes options")
                Button(action: onClose) { PanelIcon(symbol: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close bracket notes")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Picker("Show", selection: $scopeRaw) {
                ForEach(BracketNotes.Scope.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if let problem = notes.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            content(page: page, entry: entry, working: working)
        }
        .frame(maxHeight: .infinity)
        // Turning the page, highlighting, or saving a key (re)makes the notes, a moment
        // after the last change.
        .task(id: Trigger(page: page, scope: scopeRaw, focus: notes.focusSignature(page: page),
                          hasKey: notes.hasKey, apple: notes.appleReady, ocrDone: session.ocr.meta[page] == nil ? 0 : 1)) {
            // Long enough that flicking past a page doesn't send it to Claude.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            notes.refresh(page: page, scope: scope)
        }
        .sheet(isPresented: $showSetup) { BracketSetupView(notes: notes) }
    }

    /// The whole book's notes so far, one page after another: everything already
    /// transposed stays, and the list keeps to the page you're on in the PDF / Text view.
    @ViewBuilder
    private func content(page: Int, entry: BracketNotes.Entry?, working: Bool) -> some View {
        let pages = notes.pages(scope: scope, including: page)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(pages, id: \.self) { p in
                        pageSection(p, current: p == page, working: working && p == page)
                            .id(p)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Pinch to make the notes bigger or smaller (kept for next time).
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = Double(value.magnification) }
                    .onEnded { value in zoom = Self.clampZoom(zoom * Double(value.magnification)) })
            .onAppear { proxy.scrollTo(page, anchor: .top) }
            .onChange(of: page) { _, p in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(p, anchor: .top) }
            }
            .onChange(of: scopeRaw) { _, _ in proxy.scrollTo(page, anchor: .top) }
            // You moved the notes away, then scrolled the book again (even within the
            // same page): the notes come back to the page you're reading.
            .onChange(of: session.readerScrolls) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(session.currentPage, anchor: .top) }
            }
        }
    }

    @ViewBuilder
    private func pageSection(_ p: Int, current: Bool, working: Bool) -> some View {
        let entry = notes.entry(page: p, scope: scope)
        let size = CGFloat(15 * Self.clampZoom(zoom * pinch))
        VStack(alignment: .leading, spacing: 3 * size / 15) {
            HStack(spacing: 6) {
                Text(session.label(for: SlotKey(pdfIndex: p, half: 0)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(current ? Color.accentColor : Color.secondary)
                if working { ProgressView().controlSize(.mini) }
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            }
            .padding(.bottom, 4)
            if let entry, !entry.text.isEmpty {
                let focus = notes.focus(page: p)
                ForEach(Array(Self.lines(entry.text).enumerated()), id: \.offset) { _, line in
                    if line.text.isEmpty {
                        Color.clear.frame(height: size * 0.6)
                    } else {
                        let color = Self.focusColor(line.text, focus)
                        Text(line.text)
                            .font(.system(size: size, weight: line.depth == 0 ? .semibold : .regular))
                            .padding(.horizontal, color == nil ? 0 : 4)
                            .background(color?.opacity(0.28) ?? .clear)
                            .padding(.leading, CGFloat(line.depth) * size * 1.2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .opacity(working ? 0.5 : 1)
            } else if working || (current && entry == nil) {
                Text(notes.hasKey ? "Transposing with Claude…"
                     : (notes.appleReady ? "Transposing on the iPad…" : "Transposing…"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if current {
                Text(scope == .highlights
                     ? "No highlights on this page. Highlight what you want to focus on; its bracket notes appear here."
                     : "No text on this page.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    static func clampZoom(_ z: Double) -> Double { min(max(z, 0.6), 2.6) }

    private func subtitle(page: Int, entry: BracketNotes.Entry?) -> String {
        let label = session.label(for: SlotKey(pdfIndex: page, half: 0))
        let by = entry.map { e -> String in
            switch e.engine {
            case "claude": "Claude"
            case "apple": "Apple Intelligence"
            default: "simple rules"
            }
        }
        return [label, by].compactMap { $0 }.joined(separator: " · ")
    }

    struct Line {
        let depth: Int
        let text: String
    }

    /// Leading tabs are the depth (four spaces count as a tab, in case a model slips).
    static func lines(_ text: String) -> [Line] {
        text.components(separatedBy: "\n").map { raw in
            var depth = 0
            var rest = Substring(raw)
            while true {
                if rest.hasPrefix("\t") {
                    depth += 1
                    rest = rest.dropFirst()
                } else if rest.hasPrefix("    ") {
                    depth += 1
                    rest = rest.dropFirst(4)
                } else {
                    break
                }
            }
            return Line(depth: depth, text: rest.trimmingCharacters(in: .whitespaces))
        }
    }

    /// A line made from a highlighted passage takes that highlight's color: most of its
    /// longer words come from the highlight.
    static func focusColor(_ line: String, _ focus: [Highlight]) -> Color? {
        guard !focus.isEmpty else { return nil }
        func words(_ s: String) -> [String] {
            s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 }
        }
        let mine = words(line)
        guard !mine.isEmpty else { return nil }
        var best: (share: Double, color: Color)?
        for h in focus {
            let theirs = Set(words(h.text))
            let share = Double(mine.filter(theirs.contains).count) / Double(mine.count)
            if share >= 0.7, share > (best?.share ?? 0) { best = (share, h.displayColor) }
        }
        return best?.color
    }
}

/// Paste an Anthropic API key once (kept in the iPad's Keychain) so Claude writes the
/// bracket notes.
struct BracketSetupView: View {
    @ObservedObject var notes: BracketNotes
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use Apple Intelligence", isOn: $notes.useApple)
                        .disabled(!BracketApple.isAvailable)
                } header: {
                    Text("On this iPad")
                } footer: {
                    Text(BracketApple.isAvailable
                         ? "Without a Claude key (or offline), Apple's on-device model writes the notes: free, private, rougher than Claude. To spare the battery it only runs for the page you stop on, keeps every page it has done, and rests in Low Power Mode or when the iPad is warm."
                         : "Apple Intelligence isn't available here (it needs iPadOS 26 or later with Apple Intelligence turned on in Settings). Without a Claude key, notes are made by simple rules.")
                }
                Section {
                    if notes.hasKey {
                        HStack {
                            Label("API key saved", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Remove", role: .destructive) { notes.removeKey() }
                        }
                    }
                    SecureField(notes.hasKey ? "Replace key" : "Paste your Anthropic API key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") {
                        notes.saveKey(key)
                        key = ""
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Claude (best match to your style)")
                } footer: {
                    Text("With a key, Claude writes the bracket notes in your style: the text of the page you open (and your highlights) is sent to Anthropic. Each page and each highlight is billed to your key once, then kept on the iPad and never sent again unless you choose Redo. Without a key, simpler notes are made on the iPad and nothing is sent. The key is stored only in this iPad's Keychain.")
                }
            }
            .navigationTitle("Bracket Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
