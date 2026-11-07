import Foundation
import CoreGraphics
import Vision

/// Renders one PDF page and runs Apple's on-device text recognition (Vision) on it, in
/// two passes:
///  1. the whole page at high resolution;
///  2. every line Vision wasn't sure about (low confidence, or garbled-looking) is
///     rendered again on its own at more than twice the resolution and re-read, with
///     the page's own names and terms as a custom vocabulary. The better reading wins.
/// Thread-safe: called from the background OCR worker with its own CGPDFDocument.
enum OCREngine {
    /// Bumped when recognition improves; older pages are re-read in the background.
    static let version = 2

    private struct Line {
        var line: OCRLine
        var confidence: Float
    }

    static func recognize(pdf: CGPDFDocument, index: Int) -> OCRPage {
        guard let page = pdf.page(at: index + 1) else {
            return OCRPage(page: index, aspect: 1, lines: [], v: version)
        }
        let box = page.getBoxRect(.cropBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        var w = box.width, h = box.height
        if rotation == 90 || rotation == 270 { swap(&w, &h) }
        guard w > 1, h > 1 else { return OCRPage(page: index, aspect: 1, lines: [], v: version) }
        let aspect = w / h
        let size = CGSize(width: w, height: h)

        // Two-page spreads get more pixels so each book page keeps enough resolution.
        let longSide: CGFloat = aspect > 1.15 ? 3600 : 2600
        let scale = longSide / max(w, h)
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let image = render(page, size: size, crop: whole, scale: scale) else {
            return OCRPage(page: index, aspect: aspect, lines: [], v: version)
        }
        var lines = recognizeLines(in: image, crop: whole, customWords: [])
        lines = secondPass(lines, page: page, size: size, firstScale: scale)
        return OCRPage(page: index, aspect: aspect, lines: lines.map(\.line), v: version)
    }

    // MARK: Second pass

    private static let garbled = try? NSRegularExpression(pattern: #"[a-z][0-9][a-z]|[|~¦]|[a-z][A-Z]{2,}[a-z]"#)

    private static func needsSecondLook(_ l: Line) -> Bool {
        if l.confidence < 0.75 { return true }
        let t = l.line.t
        return garbled?.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil
    }

    private static func secondPass(_ lines: [Line], page: CGPDFPage, size: CGSize, firstScale: CGFloat) -> [Line] {
        let weak = lines.indices.filter { needsSecondLook(lines[$0]) }.prefix(40)
        guard !weak.isEmpty else { return lines }
        let vocabulary = pageVocabulary(lines)
        // 2.2× the first pass, capped so a crop never gets enormous.
        let scale = min(firstScale * 2.2, 4000 / max(size.width, size.height) * 2.2)
        var out = lines
        for i in weak {
            let r = lines[i].line.r
            let crop = CGRect(x: r.minX - 0.015, y: r.minY - r.height * 0.4,
                              width: r.width + 0.03, height: r.height * 1.8)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !crop.isNull, crop.width > 0.01, crop.height > 0.002,
                  let image = render(page, size: size, crop: crop, scale: scale) else { continue }
            // Keep only what's on this line (the crop may clip the neighbours).
            let found = recognizeLines(in: image, crop: crop, customWords: vocabulary)
                .filter { abs($0.line.r.midY - r.midY) < r.height * 0.5 }
                .sorted { $0.line.r.minX < $1.line.r.minX }
            guard !found.isEmpty else { continue }
            let confidence = found.map(\.confidence).reduce(0, +) / Float(found.count)
            guard confidence > lines[i].confidence + 0.05 else { continue }
            let rect = found.dropFirst().reduce(found[0].line.r) { $0.union($1.line.r) }
            out[i] = Line(line: OCRLine(t: found.map(\.line.t).joined(separator: " "), r: rect,
                                        k: found.flatMap(\.line.k)),
                          confidence: confidence)
        }
        return out
    }

    /// Capitalized words that recur on the page (names, places, terms) help Vision read
    /// the same words where they came out garbled.
    private static func pageVocabulary(_ lines: [Line]) -> [String] {
        var counts: [String: Int] = [:]
        for l in lines where l.confidence >= 0.75 {
            for k in l.line.k {
                let w = k.t.trimmingCharacters(in: .punctuationCharacters)
                guard w.count >= 4, w.first?.isUppercase == true, w.allSatisfy({ $0.isLetter || $0 == "-" })
                else { continue }
                counts[w, default: 0] += 1
            }
        }
        return counts.filter { $0.value >= 2 }.map(\.key).sorted().prefix(100).map { $0 }
    }

    // MARK: Rendering

    /// Renders the part of the displayed page given by `crop` (normalized, top-left
    /// origin) at `scale` pixels per point, in grayscale (all Vision needs).
    private static func render(_ page: CGPDFPage, size: CGSize, crop: CGRect, scale: CGFloat) -> CGImage? {
        let w = size.width, h = size.height
        let pw = Int((crop.width * w * scale).rounded()), ph = Int((crop.height * h * scale).rounded())
        guard pw > 8, ph > 8, pw < 12000, ph < 12000,
              let ctx = CGContext(
                data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        // CoreGraphics is bottom-left: move the crop's bottom-left corner to the origin.
        ctx.translateBy(x: -crop.minX * w, y: -(1 - crop.maxY) * h)
        // getDrawingTransform never scales up, so map the box 1:1 into a rect of the
        // displayed size and let the scale above do the enlarging. It applies /Rotate.
        ctx.concatenate(page.getDrawingTransform(
            .cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    // MARK: Recognition

    private static func recognizeLines(in image: CGImage, crop: CGRect, customWords: [String]) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        if !customWords.isEmpty { request.customWords = customWords }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }

        /// Vision: normalized to the image, origin bottom-left. Noter: normalized to the
        /// displayed page, origin top-left.
        let map: (CGRect) -> CGRect = { b in
            clamp(CGRect(x: crop.minX + b.minX * crop.width, y: crop.minY + (1 - b.maxY) * crop.height,
                         width: b.width * crop.width, height: b.height * crop.height))
        }

        var lines: [Line] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let lineRect = map(observation.boundingBox)
            let tokens = tokenize(text, candidate: candidate, lineRect: lineRect, map: map)
            guard !tokens.isEmpty else { continue }
            lines.append(Line(line: OCRLine(t: text, r: lineRect, k: tokens), confidence: candidate.confidence))
        }
        return lines
    }

    /// Splits a recognized line on whitespace (keeping punctuation attached to words)
    /// and finds a bounding box for every word.
    private static func tokenize(_ text: String, candidate: VNRecognizedText, lineRect: CGRect,
                                 map: (CGRect) -> CGRect) -> [OCRToken] {
        var pieces: [(range: Range<String.Index>, start: Int, end: Int)] = []
        var i = text.startIndex
        var offset = 0
        while i < text.endIndex {
            while i < text.endIndex, text[i].isWhitespace {
                i = text.index(after: i); offset += 1
            }
            guard i < text.endIndex else { break }
            var j = i
            let start = offset
            while j < text.endIndex, !text[j].isWhitespace {
                j = text.index(after: j); offset += 1
            }
            pieces.append((i..<j, start, offset))
            i = j
        }
        guard !pieces.isEmpty else { return [] }

        let total = max(offset, 1)
        func proportional(_ start: Int, _ end: Int) -> CGRect {
            let x0 = lineRect.minX + lineRect.width * CGFloat(start) / CGFloat(total)
            let x1 = lineRect.minX + lineRect.width * CGFloat(end) / CGFloat(total)
            return CGRect(x: x0, y: lineRect.minY, width: max(x1 - x0, 0.001), height: lineRect.height)
        }

        var boxes: [CGRect?] = pieces.map { piece in
            guard let obs = try? candidate.boundingBox(for: piece.range) else { return nil }
            let r = map(obs.boundingBox)
            return r.width > 0 && r.height > 0 ? r : nil
        }
        // Some OS versions hand back the whole line's box for every word; fall back
        // to proportional character positions when that happens.
        if pieces.count > 1 {
            let wide = boxes.compactMap { $0 }.filter { $0.width > lineRect.width * 0.9 }.count
            if wide >= pieces.count - 1 { boxes = Array(repeating: nil, count: pieces.count) }
        }

        return zip(pieces, boxes).map { piece, box in
            let r = box ?? proportional(piece.start, piece.end)
            return OCRToken(t: String(text[piece.range]), r: clamp(r))
        }
    }

    private static func clamp(_ r: CGRect) -> CGRect {
        let x0 = min(max(r.minX, 0), 1), x1 = min(max(r.maxX, 0), 1)
        let y0 = min(max(r.minY, 0), 1), y1 = min(max(r.maxY, 0), 1)
        return CGRect(x: x0, y: y0, width: max(x1 - x0, 0), height: max(y1 - y0, 0))
    }
}
