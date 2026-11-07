import Foundation
import NaturalLanguage

enum KeywordKind: String, CaseIterable, Identifiable {
    case person, event, place, organization, date, term

    var id: String { rawValue }

    var title: String {
        switch self {
        case .person: "People"
        case .event: "Events"
        case .place: "Places"
        case .organization: "Organizations"
        case .date: "Dates"
        case .term: "Key terms"
        }
    }

    var symbol: String {
        switch self {
        case .person: "person"
        case .event: "flag"
        case .place: "mappin.and.ellipse"
        case .organization: "building.2"
        case .date: "calendar"
        case .term: "key"
        }
    }

    /// How many of each kind the panel shows at most.
    var limit: Int {
        switch self {
        case .person, .place, .organization: 60
        case .event, .date, .term: 40
        }
    }
}

/// One mention of a key word on one book page.
struct KeywordCandidate {
    let kind: KeywordKind
    /// Normalized form used to group mentions (lowercased, lemma for terms).
    let key: String
    let display: String
    let tokens: ClosedRange<Int>
}

struct PageKeywords {
    let slot: SlotKey
    let items: [KeywordCandidate]
}

/// Finds likely key words on a book page, entirely on device:
/// * names of people, places and organizations (Apple's NaturalLanguage tagger),
/// * named events ("First World War", "Battle of Britain") and dates ("May 1940", "1940s"),
/// * nouns and two-word phrases that could be key terms (the book-wide index keeps
///   only the ones that recur).
enum KeywordExtractor {
    static func candidates(in page: LogicalPage) -> [KeywordCandidate] {
        let text = page.text
        guard !text.isEmpty, !page.tokens.isEmpty else { return [] }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        // Never pick key words out of citations or links.
        let excluded = SkipFilter.excludedRanges(in: page, options: [.citations, .links])
        var taken: [NSRange] = []
        var out: [KeywordCandidate] = []

        func overlaps(_ r: NSRange, _ list: [NSRange]) -> Bool {
            list.contains { NSIntersectionRange($0, r).length > 0 }
        }

        func tokens(_ r: NSRange) -> ClosedRange<Int>? {
            guard let a = page.tokenIndex(atUTF16: r.location),
                  let b = page.tokenIndex(atUTF16: NSMaxRange(r) - 1) else { return nil }
            return min(a, b)...max(a, b)
        }

        /// Names, events and dates claim their words so they aren't counted twice.
        func add(_ kind: KeywordKind, _ r: NSRange, key: String? = nil) {
            guard r.length > 0, NSMaxRange(r) <= ns.length,
                  !overlaps(r, excluded), !overlaps(r, taken) else { return }
            let display = clean(ns.substring(with: r))
            guard display.count >= 2, let t = tokens(r) else { return }
            taken.append(r)
            out.append(KeywordCandidate(kind: kind, key: key ?? display.lowercased(), display: display, tokens: t))
        }

        // 1. Named events.
        for regex in eventPatterns {
            for m in regex.matches(in: text, range: whole) {
                if let r = trimLeadingStopWords(m.range, in: ns) { add(.event, r) }
            }
        }

        // 2. People, places, organizations.
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = text
        let lemmaTagger = NLTagger(tagSchemes: [.lemma])
        lemmaTagger.string = text
        let nameOptions: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .nameType, options: nameOptions) { tag, range in
            var kind: KeywordKind?
            if tag == .personalName {
                kind = .person
            } else if tag == .placeName {
                kind = .place
            } else if tag == .organizationName {
                kind = .organization
            }
            let words = text[range].split(whereSeparator: \.isWhitespace)
            if let kind, words.count <= 3, text[range].first?.isUppercase == true {
                add(kind, NSRange(range, in: text))
            }
            return true
        }

        // 3. Dates.
        if let dates {
            for m in dates.matches(in: text, range: whole) { add(.date, m.range) }
        }

        // 4. Key-term candidates: lowercase nouns, and adjective/noun + noun pairs.
        struct Word {
            let range: NSRange
            let text: String
            let tag: NLTag?
            let lemma: String
        }
        var words: [Word] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .omitOther]) { tag, range in
            let surface = String(text[range])
            let lemma = lemmaTagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? surface
            words.append(Word(range: NSRange(range, in: text), text: surface, tag: tag, lemma: lemma.lowercased()))
            return true
        }
        func addTerm(_ r: NSRange, key: String) {
            guard !overlaps(r, excluded), !overlaps(r, taken), let t = tokens(r) else { return }
            out.append(KeywordCandidate(kind: .term, key: key, display: clean(ns.substring(with: r)).lowercased(),
                                        tokens: t))
        }
        for (i, w) in words.enumerated() where w.tag == .noun && isTermWord(w.text) {
            addTerm(w.range, key: w.lemma)
            guard i > 0 else { continue }
            let prev = words[i - 1]
            guard prev.tag == .noun || prev.tag == .adjective, isTermWord(prev.text) else { continue }
            let gapStart = NSMaxRange(prev.range)
            guard w.range.location - gapStart == 1, ns.substring(with: NSRange(location: gapStart, length: 1)) == " "
            else { continue }
            addTerm(NSUnionRange(prev.range, w.range), key: prev.text.lowercased() + " " + w.lemma)
        }
        return out
    }

    // MARK: Helpers

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        for suffix in ["’s", "'s"] where t.hasSuffix(suffix) {
            t.removeLast(2)
        }
        return t
    }

    private static let leadingStopWords: Set<String> = [
        "The", "A", "An", "In", "On", "At", "By", "During", "After", "Before", "This", "That", "These",
        "Those", "Its", "His", "Her", "Their", "Our", "Of", "And", "But", "When", "While", "As", "For",
        "From", "With", "To", "Since", "Until", "Throughout",
    ]

    /// "The Second World War" → "Second World War"; nil if only the head word is left.
    private static func trimLeadingStopWords(_ range: NSRange, in ns: NSString) -> NSRange? {
        var r = range
        while true {
            let s = ns.substring(with: r)
            let parts = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            guard parts.count >= 2 else { return nil }
            guard let first = parts.first, leadingStopWords.contains(first) else { return r }
            let drop = (first as NSString).length + 1
            r = NSRange(location: r.location + drop, length: r.length - drop)
        }
    }

    private static func isTermWord(_ w: String) -> Bool {
        guard w.count >= 4, let first = w.first, first.isLowercase,
              w.allSatisfy({ $0.isLetter || $0 == "-" }) else { return false }
        return !genericNouns.contains(w.lowercased())
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            assertionFailure("Noter: bad keyword pattern \(pattern): \(error)")
            return nil
        }
    }

    private static let eventHeads = "Wars?|Revolution|Treaty|Act|Movement|Conference|Crisis|Massacre|Rebellion|"
        + "Uprising|Blitz|Invasion|Offensive|Campaign|Declaration|Accords?|Agreement|Pact|Strike|Riots?|"
        + "Depression|Armistice|Raid|Occupation|Landings?|Reformation|Election|Rising|Famine|Mutiny"

    private static let eventPatterns: [NSRegularExpression] = [
        // "First World War", "Civil War", "Russian Revolution", "Easter Rising"
        regex(#"\b(?:[A-Z][\p{L}’'\-]+\s+){1,2}(?:"# + eventHeads + #")\b"#),
        // "Battle of Britain", "Treaty of Versailles", "Fall of France"
        regex(#"\b(?:Battles?|Treaty|Siege|Fall|Liberation|Invasion|Sack|Defen[cs]e|Evacuation|Partition|Congress)\s+of\s+(?:the\s+)?[A-Z][\p{L}’'\-]+(?:\s+[A-Z][\p{L}’'\-]+)?"#),
        // Single-name events
        regex(#"\b(?:D-Day|VE Day|VJ Day|V-E Day|V-J Day|Holocaust|Blitz|Kristallnacht|Dunkirk|Armistice Day)\b"#),
    ].compactMap { $0 }

    /// "1940", "1940s", "May 1940", "6 June 1944" is caught as "June 1944".
    private static let dates = regex(
        #"\b(?:(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+(?:\d{1,2},?\s+)?)?(?:1[5-9]\d{2}|20\d{2})s?\b"#)

    /// Nouns too generic to be key terms.
    private static let genericNouns: Set<String> = [
        "time", "times", "year", "years", "week", "weeks", "month", "months", "thing", "things", "part", "parts",
        "number", "numbers", "kind", "kinds", "sort", "lots", "place", "places", "case", "cases", "point",
        "points", "fact", "facts", "side", "sides", "hand", "hands", "life", "lives", "group", "groups", "area",
        "areas", "form", "forms", "level", "levels", "line", "lines", "word", "words", "name", "names", "others",
        "other", "question", "questions", "example", "examples", "order", "idea", "ideas", "reason", "reasons",
        "result", "results", "course", "matter", "matters", "problem", "problems", "page", "pages", "chapter",
        "chapters", "book", "books", "figure", "figures", "table", "tables", "section", "sections", "something",
        "anything", "everything", "nothing", "someone", "everyone", "anyone", "today", "role", "roles", "amount",
        "deal", "rest", "change", "changes", "addition", "account", "terms", "term", "view", "views", "means",
        "need", "needs", "work", "works", "aspect", "aspects", "sense", "issue", "issues", "type", "types",
        "while", "people", "person", "persons", "member", "members", "half", "whole", "less", "more", "most",
        "much", "many", "able", "same", "kind", "manner", "instance", "basis", "extent", "series", "range",
        "attempt", "attempts", "effect", "effects", "evidence", "detail", "details", "interest", "interests",
        "position", "positions", "process", "story", "stories", "study", "studies", "source", "sources",
    ]
}
