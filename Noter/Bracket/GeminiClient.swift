import Foundation

/// Talks to Google's Gemini API for Bracket Notes (it has a free tier).
enum GeminiClient {
    static let keyAccount = "gemini-api-key"
    static let fallbackModel = "gemini-2.5-flash"
    private static let modelKey = "noter.geminiModel"
    private static let othersKey = "noter.geminiOtherModels"

    /// Other models the key can use, tried when the main one is overloaded.
    static var others: [String] {
        get { UserDefaults.standard.stringArray(forKey: othersKey) ?? ["gemini-2.5-flash-lite", "gemini-2.0-flash"] }
        set { UserDefaults.standard.set(newValue, forKey: othersKey) }
    }
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
            let ranked = plain.sorted { version($0) > version($1) }
            if let best = ranked.first {
                model = best
            } else if !names.contains(model) {
                model = fallbackModel
            }
            // Stand-ins for when it is overloaded: its lighter sibling, then older ones.
            var spare = names.filter { $0 == "\(model)-lite" }
            spare += ranked.dropFirst().prefix(2)
            spare += names.filter { $0.hasPrefix("gemini-") && $0.hasSuffix("-flash-lite") && !spare.contains($0) }
                .sorted(by: >).prefix(1)
            if !spare.isEmpty { others = spare }
            return nil
        } catch {
            return "Saved, but couldn't reach Google to check the key."
        }
    }

    /// One page's notes. When the model is overloaded or over its free limit, the
    /// other models are tried straight away instead of waiting.
    static func transpose(system: String, request: String, key: String) async throws -> String {
        var failure: Error = BracketError.empty
        for (n, name) in ([model] + others.filter { $0 != model }).prefix(3).enumerated() {
            do {
                return try await transpose(model: name, retries: n == 0 ? 1 : 0, system: system,
                                           request: request, key: key)
            } catch BracketError.busy {
                failure = BracketError.busy
            } catch BracketError.server(let code, let message) where code >= 500 {
                failure = BracketError.server(code, message)
            }
        }
        throw failure
    }

    private static func transpose(model: String, retries: Int, system: String, request: String,
                                  key: String) async throws -> String {
        guard let url = URL(string: "\(base)/models/\(model):generateContent") else {
            throw BracketError.server(0, "Bad Gemini model name")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
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
                // Busy, or over the free tier's few requests a minute: one short wait,
                // then the caller moves on to another model.
                guard attempt < retries else {
                    throw status == 429 ? BracketError.busy : BracketError.server(status, message)
                }
                attempt += 1
                let asked = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                try await Task.sleep(nanoseconds: UInt64(min(asked ?? 3, 8) * 1_000_000_000))
            default:
                throw BracketError.server(status, message)
            }
        }
    }
}
