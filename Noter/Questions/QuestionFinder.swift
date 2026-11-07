import Foundation
import NaturalLanguage

enum QuestionKind: String, CaseIterable, Identifiable {
    case question, rhetorical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .question: "Question"
        case .rhetorical: "Rhetorical"
        }
    }

    var pluralTitle: String {
        switch self {
        case .question: "Questions"
        case .rhetorical: "Rhetorical"
        }
    }
}

struct QuestionCandidate {
    let kind: QuestionKind
    let text: String
    let tokens: ClosedRange<Int>
}

/// Finds the sentences on a book page that are questions, and tells genuine questions
/// apart from rhetorical ones (asked for effect, or answered by the author straight away).
enum QuestionFinder {
    static func questions(in page: LogicalPage) -> [QuestionCandidate] {
        let text = page.text
        guard !text.isEmpty, !page.tokens.isEmpty else { return [] }
        let ns = text as NSString

        // Sentences, as trimmed UTF-16 ranges.
        var sentences: [NSRange] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if let r = trimmed(NSRange(range, in: text), in: ns) { sentences.append(r) }
            return true
        }

        var out: [QuestionCandidate] = []
        for (i, r) in sentences.enumerated() {
            let sentence = ns.substring(with: r)
            guard isQuestion(sentence),
                  let a = page.tokenIndex(atUTF16: r.location),
                  let b = page.tokenIndex(atUTF16: NSMaxRange(r) - 1) else { continue }
            let next = i + 1 < sentences.count ? ns.substring(with: sentences[i + 1]) : nil
            let kind: QuestionKind = isRhetorical(sentence, next: next) ? .rhetorical : .question
            let display = sentence.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            out.append(QuestionCandidate(kind: kind, text: display, tokens: min(a, b)...max(a, b)))
        }
        return out
    }

    // MARK: Rules

    private static let closers = CharacterSet(charactersIn: "\"'”’)]»").union(.whitespacesAndNewlines)

    static func isQuestion(_ sentence: String) -> Bool {
        let end = sentence.trimmingCharacters(in: closers)
        guard end.hasSuffix("?") || end.hasSuffix("？") else { return false }
        // At least two words, so stray OCR marks aren't counted.
        return sentence.split(whereSeparator: \.isWhitespace).count >= 2
    }

    /// Asked for effect rather than for an answer:
    /// * negative openers — "Isn't it…", "Wasn't this…"
    /// * tag questions — "…, wasn't it?"
    /// * set phrases — "Who could…", "Is it any wonder…", "What else…"
    /// * hypophora — the author answers it in the very next sentence ("Because…").
    static func isRhetorical(_ sentence: String, next: String?) -> Bool {
        let s = sentence.trimmingCharacters(in: closers.union(CharacterSet(charactersIn: "\"“‘'(")))
        let range = NSRange(location: 0, length: (s as NSString).length)
        if rhetoricalPatterns.contains(where: { $0.firstMatch(in: s, range: range) != nil }) { return true }
        if let next {
            let n = next.trimmingCharacters(in: CharacterSet(charactersIn: "\"“‘'( ").union(.whitespacesAndNewlines))
            let r = NSRange(location: 0, length: (n as NSString).length)
            if let answer, answer.firstMatch(in: n, range: r) != nil { return true }
        }
        return false
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            assertionFailure("Noter: bad question pattern \(pattern): \(error)")
            return nil
        }
    }

    private static let negatives = "isn['’]t|aren['’]t|wasn['’]t|weren['’]t|don['’]t|doesn['’]t|didn['’]t|can['’]t|"
        + "couldn['’]t|won['’]t|wouldn['’]t|shouldn['’]t|haven['’]t|hasn['’]t|hadn['’]t|mustn['’]t"

    private static let rhetoricalPatterns: [NSRegularExpression] = [
        // "Isn't it obvious…?", "Wasn't this the point…?"
        regex(#"^(?:"# + negatives + #")\b"#),
        // "Is it not…?", "Was this not…?", "Did they not…?"
        regex(#"^(?:is|was|were|are|did|does|do|could|would|should|can|has|have|had)\s+\w+\s+not\b"#),
        // Tag questions: "…, wasn't it?", "…, right?"
        regex(#",\s*(?:"# + negatives + #"|right|no|surely)(?:\s+\w+)?\s*\?\s*$"#),
        // Set phrases.
        regex(#"\b(?:who could|who would|who knows|who cares|who among|who would have thought|what else|why else|how else|what more|what better|how could anyone|how can anyone|how could one|is it any wonder|is it surprising|was it any wonder|need we|need i say|what is the point|what['’]s the point|why not|why bother|what difference|who can blame|can anyone)\b"#),
        // "Surely…?", "And yet…?"
        regex(#"^(?:surely|and yet|but then|after all)\b"#),
    ].compactMap { $0 }

    /// A next sentence that answers the question.
    private static let answer = regex(
        #"^(?:because|the answer|yes\b|no\b|not\b|partly|in part|simply|perhaps because|largely because|mainly because|the reason)"#)

    /// Trims whitespace at both ends; nil if nothing is left.
    private static func trimmed(_ range: NSRange, in ns: NSString) -> NSRange? {
        var start = range.location, end = NSMaxRange(range)
        let ws = CharacterSet.whitespacesAndNewlines
        while start < end, let u = UnicodeScalar(ns.character(at: start)), ws.contains(u) { start += 1 }
        while end > start, let u = UnicodeScalar(ns.character(at: end - 1)), ws.contains(u) { end -= 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
}
