import Foundation
import NaturalLanguage

/// Bracket notes made on the iPad, without Claude: each sentence is cut into phrases
/// at its punctuation and linking words and stepped down one tab at a time. It keeps
/// every word in order, but it can't reorder or trim by meaning the way Claude does.
enum BracketRules {
    /// Words a new phrase starts at.
    private static let breakers: Set<String> = [
        "that", "which", "who", "whose", "whom", "when", "where", "while", "because", "although",
        "though", "since", "unless", "until", "whereas", "by", "through", "between", "during", "after",
        "before", "into", "against", "with", "without", "among", "following", "under", "from", "as",
    ]
    private static let turns: Set<String> = ["but", "however", "yet", "nevertheless", "instead"]
    private static let articles: Set<String> = ["the", "a", "an"]
    private static let maxDepth = 8

    static func transpose(_ text: String) -> String {
        var blocks: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            let p = paragraph.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            var lines: [String] = []
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = p
            tokenizer.enumerateTokens(in: p.startIndex..<p.endIndex) { range, _ in
                lines += sentence(String(p[range]))
                return true
            }
            if !lines.isEmpty { blocks.append(lines.joined(separator: "\n")) }
        }
        return blocks.joined(separator: "\n\n")
    }

    private struct Phrase {
        var words: [String]
        /// Ended at a comma: may be an item of a list.
        var comma = false
        var turn = false
    }

    private static func sentence(_ s: String) -> [String] {
        let words = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { return [] }
        var phrases: [Phrase] = []
        var current = Phrase(words: [])
        func bare(_ w: String) -> String {
            w.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        func close() {
            if !current.words.isEmpty { phrases.append(current) }
            current = Phrase(words: [])
        }
        for w in words {
            let b = bare(w)
            if turns.contains(b) {
                close()
                phrases.append(Phrase(words: [w.trimmingCharacters(in: CharacterSet(charactersIn: ","))], turn: true))
                continue
            }
            // A linking word starts a new phrase, once the current one says something.
            if breakers.contains(b), current.words.count >= 2 { close() }
            current.words.append(w)
            if let last = w.last, ",;:—–".contains(last) {
                current.comma = last == ","
                close()
            }
        }
        close()

        // Leading articles go ("The acquisition…" → "acquisition…").
        for i in phrases.indices where phrases[i].words.count > 1 {
            if articles.contains(bare(phrases[i].words[0])) { phrases[i].words.removeFirst() }
        }

        var out: [String] = []
        var depth = 0
        var listDepth: Int?
        for (i, p) in phrases.enumerated() {
            if p.turn {
                depth = min(depth, 1)
                listDepth = nil
                out.append(String(repeating: "\t", count: depth) + p.words.joined(separator: " "))
                depth += 1
                continue
            }
            // Short pieces separated by commas are a list: one depth for all of them.
            let short = p.words.count <= 4
            let neighbourShortComma = (i > 0 && phrases[i - 1].comma && phrases[i - 1].words.count <= 4)
                || (p.comma && i + 1 < phrases.count && phrases[i + 1].words.count <= 4)
            if short, neighbourShortComma {
                let d = listDepth ?? depth
                listDepth = d
                out.append(String(repeating: "\t", count: d) + p.words.joined(separator: " "))
                depth = min(d + 1, maxDepth)
                continue
            }
            listDepth = nil
            out.append(String(repeating: "\t", count: depth) + p.words.joined(separator: " "))
            depth = min(depth + 1, maxDepth)
        }
        return out
    }
}
