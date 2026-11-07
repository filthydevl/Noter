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
            let area = rect.insetBy(dx: -8, dy: -8)
            let scale = min(max(140 / max(rect.height, 1), 1), 6)
            let ink = PKDrawing(strokes: black).image(from: area, scale: scale)
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

    /// Any thread: read each group; keep the ones that clearly say something.
    static func recognize(_ groups: [Group]) -> [Result] {
        groups.compactMap { g -> Result? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: g.image, options: [:])
            do { try handler.perform([request]) } catch { return nil }
            // Top to bottom (Vision's origin is bottom-left).
            let observations = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            var lines: [String] = []
            var confidence: Float = 0
            for o in observations {
                guard let c = o.topCandidates(1).first, c.confidence >= 0.3 else { continue }
                lines.append(c.string)
                confidence += c.confidence
            }
            guard !lines.isEmpty else { return nil }
            confidence /= Float(lines.count)
            let text = lines.joined(separator: "\n")
            guard text.filter(\.isLetter).count >= 2, confidence >= 0.45 else { return nil }
            return Result(indices: g.indices, rect: g.rect, color: g.color, text: text, lines: lines.count)
        }
    }
}
