import UIKit
import PencilKit
import Vision

/// Turns handwriting into neat lettering ("tidy"): strokes are grouped into words /
/// lines by how close they are, each group is rendered and read with Vision's on-device
/// handwriting recognition, and groups that read confidently as text are replaced by
/// that text in the same place, size and color. Drawings, arrows and underlines don't
/// read as words and are left alone.
enum HandwritingTidier {
    /// One group of strokes ready to be read.
    struct Group {
        let indices: [Int]
        /// In page points.
        let rect: CGRect
        let color: UIColor
        let image: CGImage
    }

    struct Result {
        let indices: [Int]
        let rect: CGRect
        let color: UIColor
        let text: String
        let lines: Int
    }

    /// Main thread: group the strokes (page points) and render each group black on white.
    @MainActor
    static func prepare(_ strokes: [PKStroke], baseIndex: Int) -> [Group] {
        guard !strokes.isEmpty else { return [] }
        let rects = strokes.map(\.renderBounds)
        let heights = rects.map(\.height).sorted()
        let h = max(heights[heights.count / 2], 4)

        // Union-find over strokes that are close enough to be one word / line.
        var parent = Array(rects.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in rects.indices {
            let grown = rects[i].insetBy(dx: -h * 0.9, dy: -h * 0.3)
            for j in rects.indices where j > i && grown.intersects(rects[j]) {
                parent[find(j)] = find(i)
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in rects.indices { groups[find(i), default: []].append(i) }

        return groups.values.compactMap { members -> Group? in
            let rect = members.dropFirst().reduce(rects[members[0]]) { $0.union(rects[$1]) }
            guard rect.width > 6, rect.height > 4 else { return nil }
            // Black ink on white reads best, whatever color you wrote in.
            let black = members.map { i -> PKStroke in
                let s = strokes[i]
                return PKStroke(ink: PKInk(s.ink.inkType, color: .black), path: s.path, transform: s.transform,
                                mask: s.mask)
            }
            // Scale by the writing's line height (not the whole group's), so a paragraph
            // reads as well as a word: about 70 px per line, at most ~4000 px a side.
            let lineHeight = max(members.map { rects[$0].height }.sorted()[members.count / 2], 4)
            let area = rect.insetBy(dx: -max(lineHeight, 12), dy: -max(lineHeight * 0.6, 12))
            var scale = min(max(70 / lineHeight, 1), 6)
            scale = min(scale, 4000 / max(area.width, area.height, 1))
            // Light appearance: in Dark Mode PencilKit would draw this black ink white —
            // white on white, which reads as nothing.
            var ink = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = PKDrawing(strokes: black).image(from: area, scale: scale)
            }
            guard ink.size.width > 0, ink.size.height > 0 else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.scale = ink.scale
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: ink.size, format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: ink.size))
                ink.draw(at: .zero)
            }
            guard let cg = image.cgImage else { return nil }
            return Group(indices: members.sorted().map { $0 + baseIndex }, rect: rect,
                         color: strokes[members[0]].ink.color, image: cg)
        }
    }

    /// Any thread: read each group; keep the ones that say something. `strict` (auto-tidy
    /// while you write) only keeps confident readings, so drawings aren't turned into
    /// words; tapping Tidy takes anything that reads as words.
    static func recognize(_ groups: [Group], strict: Bool) -> [Result] {
        groups.compactMap { g -> Result? in
            // Vision scores handwriting coarsely (about 0.3 / 0.5 / 1), so 0.3 is a real reading.
            let lines = read(g.image, correcting: true) ?? read(g.image, correcting: false)
            guard let lines, !lines.isEmpty else { return nil }
            let confidence = lines.map { $0.1 }.reduce(0, +) / Float(lines.count)
            let text = lines.map { $0.0 }.joined(separator: "\n")
            let visible = text.filter { !$0.isWhitespace }
            let letters = visible.filter { $0.isLetter || $0.isNumber }
            guard letters.count >= (strict ? 2 : 1),
                  Double(letters.count) >= Double(visible.count) * 0.5,
                  confidence >= (strict ? 0.45 : 0.25) else { return nil }
            return Result(indices: g.indices, rect: g.rect, color: g.color, text: text, lines: lines.count)
        }
    }

    /// The lines Vision reads in an image, top to bottom, with their confidence.
    private static func read(_ image: CGImage, correcting: Bool) -> [(String, Float)]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = correcting
        // English is the language Vision reads handwriting best in.
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        // Top to bottom (Vision's origin is bottom-left).
        let observations = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        let lines = observations.compactMap { o -> (String, Float)? in
            guard let c = o.topCandidates(1).first, c.confidence >= 0.2,
                  !c.string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (c.string, c.confidence)
        }
        return lines.isEmpty ? nil : lines
    }
}
