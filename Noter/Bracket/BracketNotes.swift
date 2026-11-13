import Foundation

/// The bracket notes of one book: a page's text transposed into the reader's indented
/// note style. Who writes them, best first:
/// * Gemini (free tier) or Claude, when you've saved a key for one;
/// * Apple Intelligence's on-device model, without a key or offline;
/// * simple rules (`BracketRules`) as the last resort.
/// Every page's notes are kept on disk and only made again when the page's text
/// changes, a better engine becomes available, or you ask.
@MainActor
final class BracketNotes: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case highlights, page
        var id: String { rawValue }
        var title: String { self == .page ? "Whole page" : "Highlights only" }
    }

    /// Which online model to use when you have keys for both.
    enum Online: String, CaseIterable, Identifiable {
        case gemini, claude
        var id: String { rawValue }
        var title: String { self == .gemini ? "Gemini" : "Claude" }
    }

    struct Entry: Codable {
        /// The text the notes were made from: a change means redo.
        var key: String
        var text: String
        /// "gemini", "claude", "apple" (Apple Intelligence, on the iPad) or "rules".
        var engine: String
        /// The page's highlights when the notes were made (Gemini redoes the page
        /// around new highlights).
        var focus: String?
    }

    @Published private(set) var entries: [String: Entry] = [:]
    @Published private(set) var working: Set<String> = []
    @Published private(set) var problem: String?
    /// A Claude (Anthropic) key is saved.
    @Published private(set) var hasKey = false
    @Published private(set) var hasGemini = false
    @Published var preferred: Online {
        didSet { UserDefaults.standard.set(preferred.rawValue, forKey: Self.onlineKey) }
    }
    /// Use Apple Intelligence's on-device model when there's no key (or no internet),
    /// on iPads that have it.
    @Published var useApple: Bool {
        didSet { UserDefaults.standard.set(useApple, forKey: Self.appleKey) }
    }
    /// The Bracket Notes panel is on screen (the reader reports its position then).
    var isShowing = false

    private static let appleKey = "noter.bracketApple"
    private static let onlineKey = "noter.bracketOnline"

    weak var session: DocumentSession?
    private let docID: UUID
    private var apiKey: String?
    private var geminiKey: String?
    private var tasks: [String: Task<Void, Never>] = [:]

    private var url: URL { Storage.folder(docID).appendingPathComponent("bracket-notes.json") }

    init(docID: UUID) {
        self.docID = docID
        let defaults = UserDefaults.standard
        useApple = defaults.object(forKey: Self.appleKey) as? Bool ?? true
        preferred = defaults.string(forKey: Self.onlineKey).flatMap(Online.init(rawValue:)) ?? .gemini
        entries = Storage.load([String: Entry].self, from: url) ?? [:]
        apiKey = Keychain.string(BracketClient.keyAccount)
        hasKey = !(apiKey ?? "").isEmpty
        geminiKey = Keychain.string(GeminiClient.keyAccount)
        hasGemini = !(geminiKey ?? "").isEmpty
    }

    // MARK: Engines

    var appleReady: Bool { useApple && BracketApple.isAvailable }

    /// The online model in use, if a key for one is saved.
    var online: Online? {
        if hasGemini, hasKey { return preferred }
        if hasGemini { return .gemini }
        return hasKey ? .claude : nil
    }

    /// The best engine there is right now.
    var wanted: String { online?.rawValue ?? (appleReady ? "apple" : "rules") }

    private static func rank(_ engine: String) -> Int {
        switch engine {
        case "claude", "gemini": 3
        case "apple": 2
        default: 1
        }
    }

    static func name(_ engine: String) -> String {
        switch engine {
        case "gemini": "Gemini"
        case "claude": "Claude"
        case "apple": "Apple Intelligence"
        default: "simple rules"
        }
    }

    // MARK: Keys

    func saveKey(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.set(key, BracketClient.keyAccount)
        apiKey = key
        hasKey = true
        problem = nil
    }

    func removeKey() {
        Keychain.set(nil, BracketClient.keyAccount)
        apiKey = nil
        hasKey = false
    }

    /// Saves the Gemini key and looks up the newest model it can use. Returns a
    /// message to show (nil: all good).
    func saveGeminiKey(_ raw: String) async -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Paste your key first." }
        let message = await GeminiClient.setUp(key: key)
        if message?.contains("rejected") == true { return message }
        Keychain.set(key, GeminiClient.keyAccount)
        geminiKey = key
        hasGemini = true
        problem = nil
        return message
    }

    func removeGeminiKey() {
        Keychain.set(nil, GeminiClient.keyAccount)
        geminiKey = nil
        hasGemini = false
    }

    // MARK: Notes

    static func id(_ page: Int, _ scope: Scope) -> String { "\(page)-\(scope.rawValue)" }

    /// A page's notes. "Highlights only" is put together from each highlight's own
    /// saved notes (nil until the first of them is ready).
    func entry(page: Int, scope: Scope) -> Entry? {
        guard scope == .highlights else { return entries[Self.id(page, scope)] }
        let focus = focus(page: page)
        if focus.isEmpty { return Entry(key: "", text: "", engine: wanted) }
        let made = focus.compactMap { entries[Self.id($0)] }
        guard !made.isEmpty else { return nil }
        let weakest = made.map(\.engine).min { Self.rank($0) < Self.rank($1) } ?? "rules"
        return Entry(key: "", text: made.map(\.text).joined(separator: "\n\n"), engine: weakest)
    }

    /// Every page that has notes so far (plus the one you're on), in book order.
    func pages(scope: Scope, including current: Int) -> [Int] {
        var set: Set<Int> = [current]
        switch scope {
        case .page:
            let suffix = "-\(Scope.page.rawValue)"
            for (id, e) in entries where id.hasSuffix(suffix) && !e.text.isEmpty {
                if let n = Int(id.dropLast(suffix.count)) { set.insert(n) }
            }
        case .highlights:
            for h in session?.highlights ?? [] where entries[Self.id(h)] != nil && h.noteText == nil {
                set.insert(h.page)
            }
        }
        return set.sorted()
    }

    static func id(_ h: Highlight) -> String { "h-\(h.id.uuidString)" }
    func isWorking(page: Int, scope: Scope) -> Bool { working.contains(Self.id(page, scope)) }

    /// Highlights without a note on a page: what the reader is focusing on there.
    func focus(page: Int) -> [Highlight] {
        guard let s = session else { return [] }
        return s.highlights
            .filter { $0.page == page && $0.noteText == nil && !$0.text.isEmpty }
            .sorted { a, b in
                let ya = a.rects.first?.minY ?? 0, yb = b.rects.first?.minY ?? 0
                return ya != yb ? ya < yb : a.created < b.created
            }
    }

    /// Changes whenever the page's focus highlights do.
    func focusSignature(page: Int) -> String {
        focus(page: page).map { "\($0.id.uuidString):\($0.text.count)" }.joined(separator: ",")
    }

    /// Loads what a page doesn't have yet: its highlights' notes first, then the whole
    /// page's. Nothing that is already there is made again.
    func load(page: Int) {
        guard let s = session, page >= 0, page < s.pageCount else { return }
        let id = "load-\(page)"
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            _ = await s.ocr.ensure(page)
            guard let self, !Task.isCancelled else { return }
            await self.makeHighlights(page: page, id: Self.id(page, .highlights), force: false)
            guard !Task.isCancelled else { return }
            await self.make(page: page, id: Self.id(page, .page), force: false)
        }
    }

    /// Makes a page's notes again (the reload button).
    func refresh(page: Int, scope: Scope, force: Bool = false) {
        guard let s = session, page >= 0, page < s.pageCount else { return }
        let id = Self.id(page, scope)
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            _ = await s.ocr.ensure(page)
            guard let self, !Task.isCancelled else { return }
            if scope == .highlights {
                await self.makeHighlights(page: page, id: id, force: force)
            } else {
                await self.make(page: page, id: id, force: force)
            }
        }
    }

    private func make(page: Int, id: String, force: Bool) async {
        guard let s = session else { return }
        let text = Self.bodyText(s.logicalPages(page) ?? [])
        let focus = focus(page: page).map(\.text)
        let key = Self.hash(text)
        let focusKey = Self.hash(focus.joined(separator: "\u{1}"))
        let wanted = self.wanted
        // Notes that are there stay as they are, whichever model wrote them and
        // whatever has changed since: only the reload button makes them again. (An
        // empty entry from before the page's text was recognized doesn't count.)
        if !force, let e = entries[id], !e.text.isEmpty || e.key == key { return }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store(id, Entry(key: key, text: "", engine: wanted, focus: focusKey))
            return
        }
        working.insert(id)
        defer { working.remove(id) }

        if let online {
            // What the reader highlighted elsewhere in the book: the transposer's memory.
            let memory = s.highlights
                .filter { $0.page != page && $0.noteText == nil && !$0.text.isEmpty }
                .sorted { $0.created > $1.created }
                .prefix(10)
                .map { String($0.text.prefix(200)) }
            let request = BracketStyle.request(text: text, focus: focus, memory: Array(memory), onlyFocus: false)
            do {
                let notes = try await ask(online, request)
                guard !Task.isCancelled else { return }
                problem = nil
                store(id, Entry(key: key, text: notes, engine: online.rawValue, focus: focusKey))
                return
            } catch is CancellationError {
                return
            } catch let e as URLError where e.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                problem = "\(online.title): \(reason). Showing notes made on the iPad instead."
                // Keep what a model already wrote for this text; else carry on on the iPad.
                if let e = entries[id], e.key == key, Self.rank(e.engine) >= 2 { return }
            }
        }

        if appleReady, !BracketApple.shouldRest {
            if let notes = try? await BracketApple.transpose(text), !Task.isCancelled {
                if online == nil { problem = nil }
                store(id, Entry(key: key, text: notes, engine: "apple", focus: focusKey))
            }
            return
        }
        if appleReady, online == nil {
            problem = "Low Power Mode is on or the iPad is warm, so Apple Intelligence is resting. Showing simpler notes for now."
        }
        store(id, Entry(key: key, text: BracketRules.transpose(text), engine: "rules", focus: focusKey))
    }

    /// "Highlights only": each highlight is transposed once, by itself, and kept —
    /// a new highlight sends only its own text, never the page again.
    private func makeHighlights(page: Int, id: String, force: Bool) async {
        let wanted = self.wanted
        for h in focus(page: page) {
            guard !Task.isCancelled else { return }
            let hid = Self.id(h)
            let key = Self.hash(h.text)
            // A highlight that has notes keeps them; only new highlights are done.
            if !force, let e = entries[hid], !e.text.isEmpty { continue }
            working.insert(id)
            defer { working.remove(id) }
            if let online {
                do {
                    let notes = try await ask(online, BracketStyle.passage(h.text))
                    guard !Task.isCancelled else { return }
                    problem = nil
                    store(hid, Entry(key: key, text: notes, engine: online.rawValue))
                    continue
                } catch is CancellationError {
                    return
                } catch let e as URLError where e.code == .cancelled {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    problem = "\(online.title): \(reason). Showing notes made on the iPad instead."
                    if let e = entries[hid], e.key == key, Self.rank(e.engine) >= 2 { continue }
                }
            }
            if appleReady, !BracketApple.shouldRest {
                let notes = try? await BracketApple.transpose(h.text)
                guard !Task.isCancelled else { return }
                if let notes {
                    store(hid, Entry(key: key, text: notes, engine: "apple"))
                    continue
                }
            }
            store(hid, Entry(key: key, text: BracketRules.transpose(h.text), engine: "rules"))
        }
    }

    private func ask(_ online: Online, _ request: String) async throws -> String {
        switch online {
        case .gemini:
            return try await GeminiClient.transpose(system: BracketStyle.system, request: request,
                                                    key: geminiKey ?? "")
        case .claude:
            return try await BracketClient.transpose(request, key: apiKey ?? "")
        }
    }

    private func store(_ id: String, _ entry: Entry) {
        entries[id] = entry
        Storage.save(entries, to: url)
    }

    /// The page's text as read aloud: without the footnotes at its end.
    static func bodyText(_ pages: [LogicalPage]) -> String {
        pages.map { lp -> String in
            let ns = lp.text as NSString
            guard let first = lp.footnoteRanges.map(\.location).min(), first <= ns.length else { return lp.text }
            return ns.substring(to: first)
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stable across launches (Swift's own hashing isn't).
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }
}
