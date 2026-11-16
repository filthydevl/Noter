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

    /// Words in the whole book (pages not recognized yet count as the average page).
    func totalWords() -> Int? {
        let words = ocr.words
        guard !words.isEmpty, pageCount > 0 else { return nil }
        let average = Double(words.values.reduce(0, +)) / Double(words.count)
        var total = 0.0
        for i in 0..<pageCount { total += words[i].map(Double.init) ?? average }
        return Int(total.rounded())
    }
}

/// Floating at the bottom of the page: time read so far / the whole book's time, at
/// the read-aloud speed (the voice's real pace, learned as it reads). Follows the
/// reading position, or the page you scroll to (PDF or Text view).
struct ReadingTimeLabel: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var speech: SpeechController
    @ObservedObject var outline: OutlineIndex

    var body: some View {
        Group {
            if let times {
                HStack(spacing: 5) {
                    Text(times.done)
                        .foregroundStyle(.primary)
                    Text("/")
                        .foregroundStyle(.tertiary)
                    Text(times.total)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: times.done)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(times.done) read of \(times.total)")
            }
        }
        .onAppear {
            let book = session
            book.ocr.onWordsCounted = { [weak book] in book?.objectWillChange.send() }
            book.ocr.countMissingWords()
        }
    }

    private var times: (done: String, total: String)? {
        guard let left = session.wordsLeft(), let total = session.totalWords(), total > 0 else { return nil }
        let perSecond = speech.wordsPerMinuteAt1x * max(speech.speed, 0.1) / 60
        guard perSecond > 0 else { return nil }
        let all = Double(total) / perSecond
        let done = max(Double(total - left.book), 0) / perSecond
        let long = all >= 3600
        return (Self.clock(done, hours: long), Self.clock(all, hours: long))
    }

    /// "12:34", or "1:05:20" (and "0:12:34" beside an hour-long total).
    static func clock(_ seconds: Double, hours: Bool) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "–" }
        let s = Int(seconds.rounded())
        return hours ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
