import SwiftUI

extension DocumentSession {
    /// Words from where you are to the end of the book, and to the end of the part
    /// (chapter) you're in. Where you are: the word being read aloud, else the page
    /// you're on in the PDF or Text view. Pages whose text isn't recognized yet count as
    /// the average page. Nil until some page has text.
    func wordsLeft() -> (book: Int, part: Int?)? {
        let words = ocr.words
        guard !words.isEmpty, pageCount > 0 else { return nil }
        let average = Double(words.values.reduce(0, +)) / Double(words.count)
        func count(_ page: Int) -> Double { words[page].map(Double.init) ?? average }

        // Where you are, as a page plus how much of it is already behind you.
        var page = currentPage
        var done = 0.0
        if speech.isActive, let p = speechPosition, let pages = logicalPages(p.pdfIndex) {
            page = p.pdfIndex
            let total = pages.reduce(0) { $0 + $1.tokens.count }
            let before = pages.prefix(p.half).reduce(0) { $0 + $1.tokens.count } + p.token
            if total > 0 { done = min(Double(before) / Double(total), 1) }
        }
        page = max(0, min(page, pageCount - 1))

        var book = count(page) * (1 - done)
        for i in (page + 1)..<max(pageCount, page + 1) { book += count(i) }

        var part: Double?
        if let next = outline.entries.first(where: { $0.position > Double(page) + done + 0.001 }) {
            let end = min(next.position, Double(pageCount))
            var left = 0.0
            var position = Double(page) + done
            while position < end - 0.0001 {
                let i = Int(position)
                let stop = min(Double(i + 1), end)
                left += count(i) * (stop - position)
                position = stop
            }
            part = left
        }
        return (Int(book.rounded()), part.map { Int($0.rounded()) })
    }
}

/// Under PDF / Text: about how long the rest of the chapter and of the book take at
/// the read-aloud speed (the voice's real pace, learned as it reads). Follows the
/// reading position, or the page you scroll to.
struct ReadingTimeLabel: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var speech: SpeechController
    @ObservedObject var outline: OutlineIndex

    var body: some View {
        Group {
            if let text {
                Text(text)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Rectangle())
                    .accessibilityLabel("Time left: \(text)")
            }
        }
        .onAppear {
            session.ocr.onWordsCounted = { [weak session] in session?.objectWillChange.send() }
            session.ocr.countMissingWords()
        }
    }

    private var text: String? {
        guard let left = session.wordsLeft() else { return nil }
        let perMinute = speech.wordsPerMinuteAt1x * max(speech.speed, 0.1)
        let book = Self.format(Double(left.book) / perMinute)
        if let part = left.part, part < left.book {
            return "\(Self.format(Double(part) / perMinute)) left in chapter · \(book) in book"
        }
        return "\(book) left"
    }

    /// "<1 min", "12 min", "2 h 05 min"
    static func format(_ minutes: Double) -> String {
        guard minutes.isFinite, minutes >= 0 else { return "–" }
        let m = Int(minutes.rounded())
        if m < 1 { return "<1 min" }
        if m < 60 { return "\(m) min" }
        return String(format: "%d h %02d min", m / 60, m % 60)
    }
}
