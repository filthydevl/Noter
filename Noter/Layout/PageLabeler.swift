import Foundation

/// Works out the printed (in-book) page number of every book page from the page
/// numbers OCR found, rejecting misreads and filling in pages where none was printed
/// (chapter openings, blank versos, figures).
enum PageLabeler {
    /// `folios`: one entry per book page in document order. Returns a label per entry.
    static func labels(for folios: [Folio?]) -> [String?] {
        let n = folios.count
        guard n > 0 else { return [] }

        // 1. Keep detections that agree with a nearby detection (same numbering
        //    system, same step). With very few detections, trust them all.
        let detected = folios.indices.filter { folios[$0] != nil }
        let lenient = detected.count <= 2
        var valid = [Folio?](repeating: nil, count: n)
        for i in detected {
            let f = folios[i]!
            if lenient { valid[i] = f; continue }
            for j in max(0, i - 8)...min(n - 1, i + 8) where j != i {
                if let g = folios[j], g.roman == f.roman, g.value - f.value == j - i {
                    valid[i] = f
                    break
                }
            }
        }

        // 2. Nearest valid detection on each side.
        var left = [Int?](repeating: nil, count: n)
        var right = [Int?](repeating: nil, count: n)
        var last: Int?
        for i in 0..<n { if valid[i] != nil { last = i }; left[i] = last }
        last = nil
        for i in stride(from: n - 1, through: 0, by: -1) { if valid[i] != nil { last = i }; right[i] = last }

        // 3. Count forward / backward from them.
        var result = [String?](repeating: nil, count: n)
        for i in 0..<n {
            if let f = valid[i] { result[i] = format(f); continue }
            var candidate: Folio?
            if let l = left[i], let lf = valid[l] {
                candidate = Folio(value: lf.value + (i - l), roman: lf.roman)
            }
            if let r = right[i], let rf = valid[r] {
                let fromRight = Folio(value: rf.value - (r - i), roman: rf.roman)
                let preferRight: Bool
                if let l = left[i], let lf = valid[l] {
                    // Front matter (roman) ends where arabic numbering begins.
                    preferRight = lf.roman && !rf.roman && (r - i) <= (i - l)
                } else {
                    preferRight = true
                }
                if preferRight && fromRight.value >= 1 { candidate = fromRight }
            }
            if let c = candidate, c.value >= 1 { result[i] = format(c) }
        }
        return result
    }

    static func format(_ f: Folio) -> String {
        f.roman ? roman(f.value) : String(f.value)
    }

    static func roman(_ value: Int) -> String {
        guard value > 0 else { return "" }
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                      (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var v = value
        var s = ""
        for (n, r) in table {
            while v >= n { s += r; v -= n }
        }
        return s
    }
}
