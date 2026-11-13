import Foundation

/// The bracket notes of one book: a page's text transposed into the reader's indented
/// note style. Claude writes them when an Anthropic API key is saved; without a key
/// (or when Claude can't be reached) they're made on the iPad by `BracketRules`.
/// Every page's notes are kept on disk, so a page is only ever sent once per version
/// of its highlights.
@MainActor
final class BracketNotes: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case page, highlights
        var id: String { rawValue }
        var title: String { self == .page ? "Whole page" : "Highlights only" }
    }

    struct Entry: Codable {
        /// What the notes were made from (text + highlights): changes mean redo.
        var key: String
        var text: String
        /// "claude" or "rules".
        var engine: String
    }

    @Published private(set) var entries: [String: Entry] = [:]
    @Published private(set) var working: Set<String> = []
    @Published private(set) var problem: String?
    @Published private(set) var hasKey = false

    weak var session: DocumentSession?
    private let docID: UUID
    private var apiKey: String?
    private var tasks: [String: Task<Void, Never>] = [:]

    private var url: URL { Storage.folder(docID).appendingPathComponent("bracket-notes.json") }

    init(docID: UUID) {
        self.docID = docID
        entries = Storage.load([String: Entry].self, from: url) ?? [:]
        apiKey = Keychain.string(BracketClient.keyAccount)
        hasKey = !(apiKey ?? "").isEmpty
    }

    // MARK: Key

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

    // MARK: Notes

    static func id(_ page: Int, _ scope: Scope) -> String { "\(page)-\(scope.rawValue)" }

    func entry(page: Int, scope: Scope) -> Entry? { entries[Self.id(page, scope)] }
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

    /// Makes (or re-makes, if the page's text or highlights changed) a page's notes.
    func refresh(page: Int, scope: Scope, force: Bool = false) {
        guard let s = session, page >= 0, page < s.pageCount else { return }
        let id = Self.id(page, scope)
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            _ = await s.ocr.ensure(page)
            guard let self, !Task.isCancelled else { return }
            await self.make(page: page, scope: scope, id: id, force: force)
        }
    }

    private func make(page: Int, scope: Scope, id: String, force: Bool) async {
        guard let s = session else { return }
        let text = Self.bodyText(s.logicalPages(page) ?? [])
        let focus = focus(page: page).map(\.text)
        let key = Self.hash(text + "\u{1}" + focus.joined(separator: "\u{1}"))
        let wanted = hasKey ? "claude" : "rules"
        if !force, let e = entries[id], e.key == key, e.engine == wanted { return }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store(id, Entry(key: key, text: "", engine: wanted))
            return
        }
        if scope == .highlights, focus.isEmpty {
            store(id, Entry(key: key, text: "", engine: wanted))
            return
        }

        guard hasKey, let apiKey else {
            store(id, Entry(key: key, text: rules(text: text, focus: focus, scope: scope), engine: "rules"))
            return
        }

        working.insert(id)
        defer { working.remove(id) }
        // What the reader highlighted elsewhere in the book: the transposer's memory.
        let memory = s.highlights
            .filter { $0.page != page && $0.noteText == nil && !$0.text.isEmpty }
            .sorted { $0.created > $1.created }
            .prefix(25)
            .map { String($0.text.prefix(240)) }
        let request = BracketStyle.request(text: text, focus: focus, memory: Array(memory),
                                           onlyFocus: scope == .highlights)
        do {
            let notes = try await BracketClient.transpose(request, key: apiKey)
            guard !Task.isCancelled else { return }
            problem = nil
            store(id, Entry(key: key, text: notes, engine: "claude"))
        } catch is CancellationError {
            return
        } catch let e as URLError where e.code == .cancelled {
            return
        } catch {
            guard !Task.isCancelled else { return }
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            problem = "\(reason). Showing notes made on the iPad instead."
            // Never an empty panel: the on-device notes, until Claude can be reached.
            if entries[id]?.key != key || entries[id]?.engine != "claude" {
                store(id, Entry(key: key, text: rules(text: text, focus: focus, scope: scope), engine: "rules"))
            }
        }
    }

    private func rules(text: String, focus: [String], scope: Scope) -> String {
        scope == .highlights
            ? focus.map { BracketRules.transpose($0) }.joined(separator: "\n\n")
            : BracketRules.transpose(text)
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
