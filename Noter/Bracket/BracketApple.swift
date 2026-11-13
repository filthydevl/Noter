import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Bracket notes written by Apple Intelligence's on-device model (iPadOS 26+, on iPads
/// that support it): no key, no internet, nothing leaves the iPad.
///
/// Running a language model is the heaviest thing Noter does, so it is kept on a
/// short leash to spare the battery:
/// * it only ever runs for the page you've stopped on, one page at a time, and the
///   result is kept — a page is never generated twice;
/// * it isn't loaded ahead of time and nothing is generated in advance;
/// * it doesn't run in Low Power Mode or while the iPad is hot (the simple on-device
///   rules are used then);
/// * the page is fed in small pieces with a firm cap on the reply, no sampling, and a
///   pause between pieces, and turning the page stops it at once.
#if canImport(FoundationModels)
/// What the on-device model is asked to fill in: each line of the notes with its
/// depth as a number. (Asked for plain text, it left out the tabs and every line came
/// out flush left; a number it can't leave out.)
@available(iOS 26.0, *)
@Generable
struct BracketAppleLine {
    @Guide(description: "How far this phrase is indented: 0 for the phrase that starts a sentence or topic, 1 for a phrase that explains or follows from it, 2 for one that hangs from that, and so on. Items of a list share the same depth.", .range(0...8))
    var depth: Int
    @Guide(description: "One short phrase of the text, in the author's words.")
    var text: String
}

@available(iOS 26.0, *)
@Generable
struct BracketAppleNotes {
    @Guide(description: "The text as bracket notes, one phrase per line, in the text's order.")
    var lines: [BracketAppleLine]
}
#endif

enum BracketApple {
    struct Unavailable: Error {}

    /// The model is on this iPad and ready.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Low Power Mode or a hot iPad: leave the model alone for now.
    static var shouldRest: Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled
            || info.thermalState == .serious || info.thermalState == .critical
    }

    /// The model reads at most about 4,000 tokens at once (instructions, text and
    /// reply together), so the page goes in as pieces of a few sentences.
    private static let pieceLength = 900

    static func transpose(_ text: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            var blocks: [String] = []
            for (n, piece) in pieces(of: text).enumerated() {
                try Task.checkCancellation()
                // Heat or Low Power Mode part-way through: the rest by the simple rules.
                if shouldRest {
                    blocks.append(BracketRules.transpose(piece))
                    continue
                }
                if n > 0 { try await Task.sleep(nanoseconds: 300_000_000) } // let the chip breathe
                // A fresh, small session per piece: nothing piles up in its memory.
                let session = LanguageModelSession(instructions: BracketStyle.compact)
                let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 1100)
                do {
                    let reply = try await session.respond(to: piece, generating: BracketAppleNotes.self,
                                                          options: options)
                    let notes = stepped(reply.content.lines.map { (depth: $0.depth, text: $0.text) })
                    blocks.append(notes.isEmpty ? BracketRules.transpose(piece) : notes)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The model balked at this piece (too long, a guardrail…): rules for it.
                    blocks.append(BracketRules.transpose(piece))
                }
            }
            return blocks.joined(separator: "\n\n")
        }
        #endif
        throw Unavailable()
    }

    /// Whole paragraphs, then whole sentences, up to `pieceLength` characters each.
    static func pieces(of text: String) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            current = ""
        }
        for paragraph in text.components(separatedBy: "\n") {
            let p = paragraph.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            if p.count > pieceLength {
                flush()
                // A long paragraph: cut at sentence ends.
                var rest = p[...]
                while rest.count > pieceLength {
                    let window = rest.prefix(pieceLength)
                    var cut = window.lastIndex(where: { ".!?;".contains($0) }).map { rest.index(after: $0) }
                        ?? window.lastIndex(of: " ") ?? window.endIndex
                    if cut == rest.startIndex { cut = window.endIndex }
                    out.append(String(rest[..<cut]).trimmingCharacters(in: .whitespaces))
                    rest = rest[cut...]
                }
                current = String(rest)
                continue
            }
            if current.count + p.count + 1 > pieceLength { flush() }
            current += current.isEmpty ? p : "\n" + p
        }
        flush()
        return out
    }

    /// The model's lines as tab-indented text. Depths can't jump more than one step
    /// deeper at a time, and if the model left nearly everything flush left, each
    /// sentence is stepped down phrase by phrase so the notes still read as brackets.
    static func stepped(_ lines: [(depth: Int, text: String)]) -> String {
        var rows = lines.map { (depth: max($0.depth, 0), text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        guard !rows.isEmpty else { return "" }
        let flat = rows.filter { $0.depth == 0 }.count
        if rows.count >= 3, flat * 10 >= rows.count * 8 {
            var depth = 0
            var previous = ""
            for i in rows.indices {
                let t = rows[i].text
                let endsSentence = previous.isEmpty || ".!?".contains(previous.last ?? " ")
                if endsSentence {
                    depth = 0
                } else if !(previous.hasSuffix(",") && t.hasSuffix(",")) {
                    depth = min(depth + 1, 6) // items of a list stay side by side
                }
                rows[i].depth = depth
                previous = t
            }
        }
        var out: [String] = []
        var last = -1
        for row in rows {
            let depth = min(row.depth, last + 1)
            if depth == 0, last >= 0, ".!?".contains(out.last?.last ?? " ") { out.append("") }
            out.append(String(repeating: "\t", count: depth) + row.text)
            last = depth
        }
        return out.joined(separator: "\n")
    }
}
