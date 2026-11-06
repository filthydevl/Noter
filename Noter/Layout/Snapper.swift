import Foundation
import CoreGraphics

/// A pen sample that landed on a word.
/// `line` is any key that sorts in reading order (layout line index in the PDF view,
/// the y of a wrapped line in the transcript); `token` is the word index on the book page.
struct StrokeHit {
    var line: Int
    var token: Int
    var x: CGFloat
}

/// Turns a free-hand pen stroke into a clean word range, the way a real highlighter
/// would be read: one line → from the leftmost to the rightmost word touched;
/// several lines → from where the stroke starts on the first line to where it ends on
/// the last line, with the lines in between fully included.
enum Snapper {
    static func range(for hits: [StrokeHit], referenceWidth: CGFloat) -> ClosedRange<Int>? {
        guard !hits.isEmpty else { return nil }

        struct Acc {
            var minX = CGFloat.infinity, maxX = -CGFloat.infinity
            var minT = Int.max, maxT = Int.min
            var count = 0
        }
        var lines: [Int: Acc] = [:]
        for h in hits {
            var a = lines[h.line, default: Acc()]
            a.minX = min(a.minX, h.x); a.maxX = max(a.maxX, h.x)
            a.minT = min(a.minT, h.token); a.maxT = max(a.maxT, h.token)
            a.count += 1
            lines[h.line] = a
        }

        let keys = lines.keys.sorted()
        let maxCount = lines.values.map(\.count).max() ?? 0
        // Ignore lines the pen only grazed (drifting into the line below at the end of
        // a stroke is very common). Lines between two real lines are always kept.
        let strong = keys.filter { k in
            let a = lines[k]!
            return (a.maxX - a.minX) >= referenceWidth * 0.12 || Double(a.count) >= Double(maxCount) * 0.35
        }
        let chosen: [Int]
        if strong.isEmpty {
            guard let busiest = keys.max(by: { lines[$0]!.count < lines[$1]!.count }) else { return nil }
            chosen = [busiest]
        } else {
            chosen = strong
        }

        let first = lines[chosen.first!]!, last = lines[chosen.last!]!
        if chosen.count == 1 { return first.minT...first.maxT }
        let lo = first.minT, hi = last.maxT
        return min(lo, hi)...max(lo, hi)
    }
}
