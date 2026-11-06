import Foundation
import CoreGraphics
import Vision

/// Renders one PDF page and runs Apple's on-device text recognition (Vision) on it.
/// Thread-safe: called from the background OCR worker with its own CGPDFDocument.
enum OCREngine {
    static func recognize(pdf: CGPDFDocument, index: Int) -> OCRPage {
        guard let page = pdf.page(at: index + 1) else {
            return OCRPage(page: index, aspect: 1, lines: [])
        }
        let box = page.getBoxRect(.cropBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        var w = box.width, h = box.height
        if rotation == 90 || rotation == 270 { swap(&w, &h) }
        guard w > 1, h > 1 else { return OCRPage(page: index, aspect: 1, lines: []) }
        let aspect = w / h

        // Two-page spreads get more pixels so each book page keeps enough resolution.
        let longSide: CGFloat = aspect > 1.15 ? 3600 : 2600
        let scale = longSide / max(w, h)
        let pw = Int((w * scale).rounded()), ph = Int((h * scale).rounded())

        // Grayscale is all Vision needs and uses a quarter of the memory of RGBA.
        guard let ctx = CGContext(
            data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return OCRPage(page: index, aspect: aspect, lines: []) }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        // getDrawingTransform never scales up, so map the box 1:1 into a rect of the
        // displayed size and let the scale above do the enlarging. It applies /Rotate.
        ctx.concatenate(page.getDrawingTransform(
            .cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)

        guard let image = ctx.makeImage() else { return OCRPage(page: index, aspect: aspect, lines: []) }
        return OCRPage(page: index, aspect: aspect, lines: recognizeLines(in: image))
    }

    private static func recognizeLines(in image: CGImage) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }

        var lines: [OCRLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let lineRect = flip(observation.boundingBox)
            let tokens = tokenize(text, candidate: candidate, lineRect: lineRect)
            guard !tokens.isEmpty else { continue }
            lines.append(OCRLine(t: text, r: lineRect, k: tokens))
        }
        return lines
    }

    /// Splits a recognized line on whitespace (keeping punctuation attached to words)
    /// and finds a bounding box for every word.
    private static func tokenize(_ text: String, candidate: VNRecognizedText, lineRect: CGRect) -> [OCRToken] {
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
            let r = flip(obs.boundingBox)
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

    /// Vision: origin bottom-left. Noter: origin top-left.
    private static func flip(_ r: CGRect) -> CGRect {
        clamp(CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height))
    }

    private static func clamp(_ r: CGRect) -> CGRect {
        let x0 = min(max(r.minX, 0), 1), x1 = min(max(r.maxX, 0), 1)
        let y0 = min(max(r.minY, 0), 1), y1 = min(max(r.maxY, 0), 1)
        return CGRect(x: x0, y: y0, width: max(x1 - x0, 0), height: max(y1 - y0, 0))
    }
}
