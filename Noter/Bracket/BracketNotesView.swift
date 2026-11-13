import SwiftUI
import UIKit

/// The Bracket Notes panel: the page you're on, transposed sentence by sentence into
/// your indented note style. Highlights (without a note) are what you're focusing on:
/// the notes are redone around them and their lines take the highlight's color.
struct BracketNotesView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var notes: BracketNotes
    /// Where the PDF / Text view is (the sentence at its top), while this panel is open.
    @ObservedObject var position: ReaderPosition
    var onClose: () -> Void
    @AppStorage("noter.bracketScope") private var scopeRaw = BracketNotes.Scope.page.rawValue
    @State private var showSetup = false
    /// Text size of the notes (pinch, or Larger / Smaller in the menu).
    @AppStorage("noter.bracketZoom") private var zoom = 1.0
    @GestureState private var pinch = 1.0
    /// When you last moved the notes yourself (read-along doesn't pull them back at once).
    @State private var lastTouched = Date.distantPast

    /// The line of the notes (and the word in it) being read aloud right now.
    struct Spoken: Equatable {
        var page: Int
        var line: Int
        var word: String
    }

    private var spoken: Spoken? {
        guard session.speech.isActive, let pos = session.speechPosition,
              let entry = notes.entry(page: pos.pdfIndex, scope: scope), !entry.text.isEmpty,
              let pages = session.logicalPages(pos.pdfIndex) else { return nil }
        let before = pages.prefix(pos.half).reduce(0) { $0 + $1.tokens.count }
        let words = pages.flatMap { $0.tokens.map(\.text) }
        let index = before + pos.token
        guard index >= 0, index < words.count else { return nil }
        let map = BracketAlign.lines(for: words, notes: entry.text, key: "\(pos.pdfIndex)-\(scopeRaw)")
        guard index < map.count, map[index] >= 0 else { return nil }
        return Spoken(page: pos.pdfIndex, line: map[index], word: BracketAlign.normal(words[index]))
    }

    private var scope: BracketNotes.Scope { BracketNotes.Scope(rawValue: scopeRaw) ?? .page }

    private struct Trigger: Equatable {
        var page: Int
        var scope: String
        var focus: String
        var engine: String
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
                        Label("Engines & keys…", systemImage: "gearshape")
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if notes.online != nil {
                        Button {
                            notes.refresh(page: page, scope: scope)
                        } label: {
                            Label("Try \(notes.online?.title ?? "") again", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                        }
                        .disabled(working)
                    }
                }
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
                          engine: notes.wanted, ocrDone: session.ocr.meta[page] == nil ? 0 : 1)) {
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
        let spoken = self.spoken
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(pages, id: \.self) { p in
                        pageSection(p, current: p == page, working: working && p == page,
                                    spoken: spoken?.page == p ? spoken : nil)
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
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in lastTouched = Date() })
            // Read-aloud: the notes follow the voice line by line (unless you've just
            // moved them yourself).
            .onChange(of: spoken?.line) { _, _ in
                guard let spoken, Date().timeIntervalSince(lastTouched) > 4 else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(Self.lineID(spoken.page, spoken.line), anchor: .center)
                }
            }
            .onAppear {
                notes.isShowing = true
                session.readerMoved(now: true)
                follow(proxy, animated: false)
            }
            .onDisappear { notes.isShowing = false }
            // The notes keep to the sentence at the top of the PDF / Text view: scroll
            // the book and they follow, line by line. (Scrolling the notes themselves
            // leaves the book where it is, until you scroll the book again.)
            .onChange(of: position.anchor) { _, _ in follow(proxy, animated: true) }
            // Touching, highlighting or writing beside a sentence in the Text view
            // brings its notes to the middle of the panel.
            .onChange(of: position.touched) { _, t in
                if let t { follow(proxy, animated: true, to: t.anchor) }
            }
            .onChange(of: page) { _, _ in follow(proxy, animated: true) }
            .onChange(of: scopeRaw) { _, _ in follow(proxy, animated: false) }
        }
    }

    @ViewBuilder
    private func pageSection(_ p: Int, current: Bool, working: Bool, spoken: Spoken?) -> some View {
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
                ForEach(Array(Self.lines(entry.text).enumerated()), id: \.offset) { offset, line in
                    if line.text.isEmpty {
                        Color.clear.frame(height: size * 0.6)
                    } else {
                        let color = Self.focusColor(line.text, focus)
                        // The line being read aloud, in the read-aloud color, with the
                        // word itself marked.
                        let speaking = spoken?.line == offset
                        Text(speaking ? Self.marking(spoken?.word ?? "", in: line.text) : AttributedString(line.text))
                            .font(.system(size: size, weight: line.depth == 0 ? .semibold : .regular))
                            .padding(.horizontal, color == nil && !speaking ? 0 : 4)
                            .background(speaking ? Color.accentColor.opacity(0.2) : (color?.opacity(0.28) ?? .clear))
                            .padding(.leading, CGFloat(line.depth) * size * 1.2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(Self.lineID(p, offset))
                    }
                }
                .opacity(working ? 0.5 : 1)
            } else if working || (current && entry == nil) {
                Text("Transposing with \(BracketNotes.name(notes.wanted))…")
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

    /// Scrolls the notes to the line for the sentence at the top of the reader (the
    /// page's notes, if that sentence can't be placed).
    private func follow(_ proxy: ScrollViewProxy, animated: Bool, to touched: TextAnchor? = nil) {
        var page = session.currentPage
        var line: Int?
        if let anchor = touched ?? position.anchor, let entry = notes.entry(page: anchor.slot.pdfIndex, scope: scope),
           !entry.text.isEmpty, let pages = session.logicalPages(anchor.slot.pdfIndex) {
            page = anchor.slot.pdfIndex
            let before = pages.prefix(anchor.slot.half).reduce(0) { $0 + $1.tokens.count }
            let words = pages.flatMap { $0.tokens.map(\.text) }
            let map = BracketAlign.lines(for: words, notes: entry.text, key: "\(page)-\(scopeRaw)")
            let index = before + anchor.token
            // The first words of a page: its heading line, so the page number shows.
            if touched != nil || index > 8, index >= 0, index < map.count, map[index] > 0 { line = map[index] }
        }
        let place: UnitPoint = touched == nil ? .top : .center
        let go = {
            if let line {
                proxy.scrollTo(Self.lineID(page, line), anchor: place)
            } else {
                proxy.scrollTo(page, anchor: .top)
            }
        }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { go() }
        } else {
            go()
        }
    }

    static func clampZoom(_ z: Double) -> Double { min(max(z, 0.6), 2.6) }

    static func lineID(_ page: Int, _ line: Int) -> String { "\(page)-line-\(line)" }

    /// The line with the spoken word marked (the first word in it that matches).
    static func marking(_ word: String, in line: String) -> AttributedString {
        var out = AttributedString(line)
        guard !word.isEmpty else { return out }
        var start = line.startIndex
        for piece in line.split(separator: " ", omittingEmptySubsequences: false) {
            let end = line.index(start, offsetBy: piece.count)
            if BracketAlign.same(BracketAlign.normal(String(piece)), word),
               let a = AttributedString.Index(start, within: out), let b = AttributedString.Index(end, within: out) {
                out[a..<b].backgroundColor = Color.accentColor.opacity(0.45)
                break
            }
            start = end < line.endIndex ? line.index(after: end) : end
        }
        return out
    }

    private func subtitle(page: Int, entry: BracketNotes.Entry?) -> String {
        let label = session.label(for: SlotKey(pdfIndex: page, half: 0))
        let by = entry.map { BracketNotes.name($0.engine) }
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
            var spaces = 0
            var rest = Substring(raw)
            while let c = rest.first, c == "\t" || c == " " {
                if c == "\t" { depth += 1 } else { spaces += 1 }
                rest = rest.dropFirst()
            }
            // Spaces instead of tabs: two (or four) to a step.
            depth += spaces / (spaces % 4 == 0 ? 4 : 2)
            // A stray list marker in front of the phrase.
            for marker in ["- ", "* ", "• ", "– "] where rest.hasPrefix(marker) {
                rest = rest.dropFirst(marker.count)
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

/// Who writes the bracket notes: keys for Gemini and Claude (kept in the iPad's
/// Keychain) and Apple Intelligence for offline.
struct BracketSetupView: View {
    @ObservedObject var notes: BracketNotes
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var geminiKey = ""
    @State private var geminiModel = GeminiClient.model
    @State private var checking = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                if notes.hasGemini, notes.hasKey {
                    Section {
                        Picker("Write notes with", selection: $notes.preferred) {
                            ForEach(BracketNotes.Online.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text("You have keys for both. The other one isn't used.")
                    }
                }

                Section {
                    if notes.hasGemini {
                        HStack {
                            Label("Gemini key saved", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Remove", role: .destructive) { notes.removeGeminiKey() }
                        }
                    }
                    SecureField(notes.hasGemini ? "Replace key" : "Paste your Gemini API key", text: $geminiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        let k = geminiKey
                        checking = true
                        message = nil
                        Task { @MainActor in
                            message = await notes.saveGeminiKey(k)
                            if notes.hasGemini { geminiKey = "" }
                            geminiModel = GeminiClient.model
                            if message == nil { message = "Key saved. Using \(GeminiClient.model)." }
                            checking = false
                        }
                    } label: {
                        if checking { ProgressView() } else { Text("Save key") }
                    }
                    .disabled(geminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
                    if notes.hasGemini {
                        TextField("Model", text: $geminiModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { GeminiClient.model = geminiModel.trimmingCharacters(in: .whitespaces) }
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Gemini (free tier)")
                } footer: {
                    Text("Get a free key at aistudio.google.com. The text of the page you open (and your highlights) is sent to Google; on the free tier Google may use what you send to improve its products, and there's a limit of a few requests a minute. The page is redone around new highlights as you make them.")
                }

                Section {
                    if notes.hasKey {
                        HStack {
                            Label("Claude key saved", systemImage: "checkmark.seal.fill")
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
                    Text("Claude (paid)")
                } footer: {
                    Text("The page's text and your highlights are sent to Anthropic and billed to your key. To save credits, a page Claude has written isn't sent again for new highlights (they're tinted instead); Redo sends it again.")
                }

                Section {
                    Toggle("Use Apple Intelligence", isOn: $notes.useApple)
                        .disabled(!BracketApple.isAvailable)
                } header: {
                    Text("Offline, on this iPad")
                } footer: {
                    Text(BracketApple.isAvailable
                         ? "Without a key, or when the internet can't be reached, Apple's on-device model writes the notes: free, private, rougher. To spare the battery it only runs for the page you stop on, keeps every page it has done, and rests in Low Power Mode or when the iPad is warm."
                         : "Apple Intelligence isn't available here (it needs iPadOS 26 or later with Apple Intelligence turned on in Settings). Offline, notes are made by simple rules.")
                }
            }
            .navigationTitle("Bracket Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if notes.hasGemini { GeminiClient.model = geminiModel.trimmingCharacters(in: .whitespaces) }
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Lines up the page's words with the lines of its bracket notes, so read-aloud can
/// show where the voice is in the notes. The notes keep the page's order (only the
/// phrases inside a sentence move), so each word is looked for in the lines around
/// where the previous word was found.
@MainActor
enum BracketAlign {
    private static var cache: [String: (signature: Int, map: [Int])] = [:]

    nonisolated static func normal(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The same word, allowing for OCR repairs in the notes ("con ict" → "conflict").
    nonisolated static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return !a.isEmpty }
        guard a.count >= 4, b.count >= 4 else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a) || a.hasSuffix(b) || b.hasSuffix(a)
    }

    /// For every word of the page, the line of the notes it's on (-1: before any match).
    static func lines(for words: [String], notes: String, key: String) -> [Int] {
        let signature = notes.count &* 31 &+ words.count
        if let hit = cache[key], hit.signature == signature { return hit.map }
        let lineWords = BracketNotesView.lines(notes).map { line in
            line.text.split(separator: " ").map { normal(String($0)) }.filter { !$0.isEmpty }
        }
        var map: [Int] = []
        map.reserveCapacity(words.count)
        var at = -1
        for raw in words {
            let w = normal(raw)
            if w.count >= 2, !lineWords.isEmpty {
                // Nearest line first: this one, the next few, then a couple back.
                let here = max(at, 0)
                var found: Int?
                for step in [0, 1, 2, -1, 3, -2, 4, 5, -3, 6, 7, 8] {
                    let i = here + step
                    guard i >= 0, i < lineWords.count else { continue }
                    // Short words ("of", "in") only count on the current line.
                    if w.count < 4, step != 0 { continue }
                    if lineWords[i].contains(where: { same($0, w) }) {
                        found = i
                        break
                    }
                }
                if let found { at = found }
            }
            map.append(at)
        }
        if cache.count > 40 { cache.removeAll() }
        cache[key] = (signature, map)
        return map
    }
}
