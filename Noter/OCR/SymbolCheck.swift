import Foundation

/// Punctuation sanity checks for recognized text. Vision occasionally reads a full
/// stop, a note number or a smudge as "?", or "(" as "{", "I"/"l" as "|".
enum SymbolCheck {
    /// Characters that are almost never right in book prose.
    private static let rare: Set<Character> = ["{", "}", "|", "¦", "~"]

    /// Has a "?" ending a stretch that isn't worded like a question, or a rare symbol.
    static func isSuspicious(_ text: String) -> Bool {
        text.contains(where: { rare.contains($0) }) || hasUnlikelyQuestionMark(text)
    }

    /// Only sentences that start on this line are judged: the first stretch of a line
    /// may be the end of a question that began on the line above.
    static func hasUnlikelyQuestionMark(_ text: String) -> Bool {
        var segmentStart: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "?" || c == "？", let start = segmentStart {
                let segment = String(text[start...i])
                if !QuestionFinder.looksInterrogative(segment) { return true }
            }
            if c == "." || c == "!" || c == "?" || c == "？" { segmentStart = text.index(after: i) }
            i = text.index(after: i)
        }
        return false
    }

    /// Same letters and digits, ignoring punctuation and spaces.
    static func sameWords(_ a: String, _ b: String) -> Bool {
        a.filter { $0.isLetter || $0.isNumber } == b.filter { $0.isLetter || $0.isNumber }
    }

    /// Fixes look-alike symbols in one word: "{" → "(", "}" → ")", a lone "|" → "I",
    /// "|" inside a word → "l", doubled commas and quote marks.
    static func clean(_ word: String) -> String {
        guard word.contains(where: { rare.contains($0) || $0 == "," || $0 == "'" || $0 == "`" }) else { return word }
        if word == "|" || word == "¦" { return "I" }
        var chars = Array(word)
        for k in chars.indices where chars[k] == "|" || chars[k] == "¦" {
            let before = k > 0 && chars[k - 1].isLetter
            let after = k + 1 < chars.count && chars[k + 1].isLetter
            chars[k] = before || after ? "l" : "I"
        }
        var s = String(chars)
            .replacingOccurrences(of: "{", with: "(")
            .replacingOccurrences(of: "}", with: ")")
            .replacingOccurrences(of: ",,", with: ",")
            .replacingOccurrences(of: "''", with: "\"")
            .replacingOccurrences(of: "``", with: "\"")
        if s.hasPrefix("~") { s.removeFirst() }
        return s.isEmpty ? word : s
    }
}
