import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Bracket notes written by Apple Intelligence's on-device model (iPadOS 26+, on iPads
/// that support it): no key, no internet, nothing leaves the iPad.
///
/// Running a language model is the heaviest thing Noter does, so it is kept on a
/// short leash to spare the battery:
/// * it only ever runs for the page you've stopped on, one page at a time, and the
///   result is kept — a page is never generated twice;
/// * it isn't loaded ahead of time and nothing is generated in advance;
/// * it doesn't run in Low Power Mode or while the iPad is hot (the simple on-device
///   rules are used then);
/// * the page is fed in small pieces with a firm cap on the reply, no sampling, and a
///   pause between pieces, and turning the page stops it at once.
enum BracketApple {
    struct Unavailable: Error {}

    /// The model is on this iPad and ready.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Low Power Mode or a hot iPad: leave the model alone for now.
    static var shouldRest: Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled
            || info.thermalState == .serious || info.thermalState == .critical
    }

    /// The model reads at most about 4,000 tokens at once (instructions, text and
    /// reply together), so the page goes in as pieces of a few sentences.
    private static let pieceLength = 900

    static func transpose(_ text: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            var blocks: [String] = []
            for (n, piece) in pieces(of: text).enumerated() {
                try Task.checkCancellation()
                // Heat or Low Power Mode part-way through: the rest by the simple rules.
                if shouldRest {
                    blocks.append(BracketRules.transpose(piece))
                    continue
                }
                if n > 0 { try await Task.sleep(nanoseconds: 300_000_000) } // let the chip breathe
                // A fresh, small session per piece: nothing piles up in its memory.
                let session = LanguageModelSession(instructions: BracketStyle.compact)
                let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 700)
                do {
                    let reply = try await session.respond(to: piece, options: options)
                    let notes = clean(reply.content)
                    blocks.append(notes.isEmpty ? BracketRules.transpose(piece) : notes)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The model balked at this piece (too long, a guardrail…): rules for it.
                    blocks.append(BracketRules.transpose(piece))
                }
            }
            return blocks.joined(separator: "\n\n")
        }
        #endif
        throw Unavailable()
    }

    /// Whole paragraphs, then whole sentences, up to `pieceLength` characters each.
    static func pieces(of text: String) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            current = ""
        }
        for paragraph in text.components(separatedBy: "\n") {
            let p = paragraph.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            if p.count > pieceLength {
                flush()
                // A long paragraph: cut at sentence ends.
                var rest = p[...]
                while rest.count > pieceLength {
                    let window = rest.prefix(pieceLength)
                    var cut = window.lastIndex(where: { ".!?;".contains($0) }).map { rest.index(after: $0) }
                        ?? window.lastIndex(of: " ") ?? window.endIndex
                    if cut == rest.startIndex { cut = window.endIndex }
                    out.append(String(rest[..<cut]).trimmingCharacters(in: .whitespaces))
                    rest = rest[cut...]
                }
                current = String(rest)
                continue
            }
            if current.count + p.count + 1 > pieceLength { flush() }
            current += current.isEmpty ? p : "\n" + p
        }
        flush()
        return out
    }

    /// Small models like to wrap replies in code fences or add a lead-in line.
    private static func clean(_ reply: String) -> String {
        var lines = reply.components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        if let first = lines.first, first.hasSuffix(":"), first.lowercased().contains("notes") { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}
