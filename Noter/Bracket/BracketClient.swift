import Foundation

enum BracketError: LocalizedError {
    case badKey
    case busy
    case declined
    case server(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .badKey: "The Anthropic API key was rejected"
        case .busy: "Claude is busy right now (too many requests)"
        case .declined: "Claude declined to transpose this page"
        case .server(let code, let message): message.isEmpty ? "Claude error \(code)" : message
        case .empty: "Claude sent back nothing"
        }
    }
}

/// Talks to the Claude API (Messages) for Bracket Notes. There is no official Swift
/// SDK, so this is the plain HTTP request.
enum BracketClient {
    static let keyAccount = "anthropic-api-key"
    static let model = "claude-opus-5-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// One page's notes. The style guide is the cached system prompt; the page is the
    /// user message.
    static func transpose(_ request: String, key: String) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // If the model's safety checks decline a page, another model takes the request.
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            // Restructuring a page is light work: low effort keeps it quick and cheap.
            "output_config": ["effort": "low"],
            "fallbacks": "default",
            "system": [[
                "type": "text",
                "text": BracketStyle.system,
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": [["role": "user", "content": request]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if status == 200, let json {
                if json["stop_reason"] as? String == "refusal" { throw BracketError.declined }
                let blocks = json["content"] as? [[String: Any]] ?? []
                let text = blocks.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined()
                let trimmed = text.trimmingCharacters(in: .newlines)
                guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty else { throw BracketError.empty }
                return trimmed
            }
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            switch status {
            case 401, 403:
                throw BracketError.badKey
            case 429, 500...599:
                // Busy or a hiccup: wait as long as asked (or 2 s, 4 s) and try again.
                guard attempt < 2 else {
                    throw status == 429 ? BracketError.busy : BracketError.server(status, message)
                }
                attempt += 1
                let asked = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                let wait = min(asked ?? Double(attempt * 2), 20)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            default:
                throw BracketError.server(status, message)
            }
        }
    }
}
