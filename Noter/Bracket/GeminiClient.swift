import Foundation

/// Talks to Google's Gemini API for Bracket Notes (it has a free tier).
enum GeminiClient {
    static let keyAccount = "gemini-api-key"
    static let fallbackModel = "gemini-2.5-flash"
    private static let modelKey = "noter.geminiModel"
    private static let base = "https://generativelanguage.googleapis.com/v1beta"

    /// The model in use: the one you typed in, else the newest "flash" model your key
    /// offers (looked up once), else a known one.
    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? fallbackModel }
        set { UserDefaults.standard.set(newValue.isEmpty ? nil : newValue, forKey: modelKey) }
    }

    /// Checks the key and picks the newest general-purpose flash model it can use.
    /// Returns nil when everything worked, else a message to show.
    static func setUp(key: String) async -> String? {
        var req = URLRequest(url: URL(string: "\(base)/models?pageSize=200")!)
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return status == 400 || status == 401 || status == 403
                    ? "Google rejected this key. Check it and try again."
                    : "Saved, but couldn't check the key (error \(status))."
            }
            let models = json["models"] as? [[String: Any]] ?? []
            let names = models.compactMap { m -> String? in
                guard let name = (m["name"] as? String)?.replacingOccurrences(of: "models/", with: ""),
                      (m["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true
                else { return nil }
                return name
            }
            // "gemini-<version>-flash", nothing specialised or experimental.
            let plain = names.filter { n in
                n.hasPrefix("gemini-") && n.hasSuffix("-flash")
            }
            func version(_ n: String) -> Double {
                Double(n.dropFirst("gemini-".count).dropLast("-flash".count)) ?? 0
            }
            if let best = plain.max(by: { version($0) < version($1) }) {
                model = best
            } else if !names.contains(model) {
                model = fallbackModel
            }
            return nil
        } catch {
            return "Saved, but couldn't reach Google to check the key."
        }
    }

    /// One page's notes.
    static func transpose(system: String, request: String, key: String) async throws -> String {
        guard let url = URL(string: "\(base)/models/\(model):generateContent") else {
            throw BracketError.server(0, "Bad Gemini model name")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": request]]]],
            "generationConfig": ["temperature": 0.2],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if status == 200, let json {
                let candidate = (json["candidates"] as? [[String: Any]])?.first
                let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                let text = parts.filter { $0["thought"] as? Bool != true }
                    .compactMap { $0["text"] as? String }.joined()
                let trimmed = text.trimmingCharacters(in: .newlines)
                if trimmed.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Blocked by a safety filter, or nothing came back.
                    let blocked = (json["promptFeedback"] as? [String: Any])?["blockReason"] != nil
                        || (candidate?["finishReason"] as? String).map { $0 != "STOP" && $0 != "MAX_TOKENS" } == true
                    throw blocked ? BracketError.declined : BracketError.empty
                }
                return trimmed
            }
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            switch status {
            case 401, 403:
                throw BracketError.badKey
            case 400 where message.localizedCaseInsensitiveContains("API key"):
                throw BracketError.badKey
            case 429, 500...599:
                // The free tier allows a few requests a minute: wait and try again.
                guard attempt < 2 else {
                    throw status == 429 ? BracketError.busy : BracketError.server(status, message)
                }
                attempt += 1
                let asked = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                try await Task.sleep(nanoseconds: UInt64(min(asked ?? Double(attempt * 6), 30) * 1_000_000_000))
            default:
                throw BracketError.server(status, message)
            }
        }
    }
}
