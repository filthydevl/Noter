import AVFoundation
import CryptoKit
import Foundation
import Security

// MARK: - Keychain

/// The Speechify API key lives in the iPad's Keychain, never in the app's files or code.
enum Keychain {
    private static let service = "com.filthydevl.noter"

    static func string(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, _ account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Readable with the screen locked, so reading aloud keeps going in the background.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Types

struct SpeechifyVoice: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var locale: String
    var gender: String
    var models: [String]
    var preview: String?

    /// "en-US · female"
    var detail: String {
        [locale, gender].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The best model this voice supports (nil: let the API choose).
    var bestModel: String? {
        for m in ["simba-3.2", "simba-3.0", "simba-english", "simba-multilingual"] where models.contains(m) {
            return m
        }
        return models.first
    }
}

/// One spoken word: its characters in the request text (UTF-16) and when it's said.
struct WordMark: Codable {
    let start: Int
    let end: Int
    let startMs: Double
    let endMs: Double
}

/// Decoded audio for one chunk of text, ready to schedule.
struct SpeechifyAudio {
    let buffer: AVAudioPCMBuffer
    let marks: [WordMark]
    let durationMs: Double

    /// Character offset (in the chunk text) of the word being said at `ms`.
    func characterOffset(atMs ms: Double, length: Int) -> Int {
        guard !marks.isEmpty else {
            // No timestamps: estimate from how far through the audio we are.
            return min(length, max(0, Int(Double(length) * ms / max(durationMs, 1))))
        }
        var lo = 0, hi = marks.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if marks[mid].startMs <= ms { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return min(max(marks[best].start, 0), length)
    }
}

enum SpeechifyError: LocalizedError {
    case noKey
    case http(Int, String)
    case badResponse
    case badAudio

    var errorDescription: String? {
        switch self {
        case .noKey: "No Speechify API key"
        case .http(401, _), .http(403, _): "the API key was rejected"
        case .http(402, _): "out of Speechify credits"
        case .http(429, _): "too many requests, slow down"
        case .http(let code, let message): message.isEmpty ? "server error \(code)" : message
        case .badResponse: "unexpected response from Speechify"
        case .badAudio: "couldn't decode Speechify audio"
        }
    }

    var isAuthProblem: Bool {
        if case .http(let code, _) = self { return code == 401 || code == 403 }
        return false
    }
}

// MARK: - Client

/// Talks to the Speechify text-to-speech API and caches every clip on disk, so text
/// you've heard before plays instantly and isn't billed again.
actor SpeechifyClient {
    static let shared = SpeechifyClient()

    /// Current host first; the older host is tried if the first can't be reached.
    private static let hosts = ["https://api.speechify.ai", "https://api.sws.speechify.com"]
    private var hostIndex = 0

    // MARK: One request at a time
    // Speechify limits how fast an account may ask; reading ahead used to fire several
    // clips at once (and again on every tap of a word) and got "too many requests".
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastStart = Date.distantPast
    /// The shortest gap between two requests.
    private static let spacing: TimeInterval = 0.35

    private func acquire() async {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        let wait = Self.spacing - Date().timeIntervalSince(lastStart)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastStart = Date()
    }

    private func release() {
        busy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Speechify", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        let dir = cacheDir
        Task.detached(priority: .background) { Self.prune(dir, maxBytes: 400 * 1024 * 1024) }
    }

    // MARK: Voices

    func voices(key: String) async throws -> [SpeechifyVoice] {
        let data = try await send("/v1/voices", method: "GET", body: nil, key: key)
        let any = try JSONSerialization.jsonObject(with: data)
        let list = (any as? [[String: Any]]) ?? ((any as? [String: Any])?["voices"] as? [[String: Any]]) ?? []
        return list.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            let models = (d["models"] as? [[String: Any]]) ?? []
            let firstLanguage = (models.first?["languages"] as? [[String: Any]])?.first
            return SpeechifyVoice(
                id: id,
                name: (d["display_name"] as? String) ?? (d["name"] as? String) ?? id,
                locale: (d["locale"] as? String) ?? (firstLanguage?["locale"] as? String) ?? "",
                gender: (d["gender"] as? String) ?? "",
                models: models.compactMap { $0["name"] as? String },
                preview: (d["preview_audio"] as? String) ?? (firstLanguage?["preview_audio"] as? String))
        }
    }

    // MARK: Speech

    private struct CacheEntry: Codable {
        let ext: String
        let marks: [WordMark]
    }

    func speech(text: String, voice: String, model: String?, key: String,
                format: AVAudioFormat) async throws -> SpeechifyAudio {
        let id = Self.hash("\(voice)|\(model ?? "-")|\(text)")
        let entryURL = cacheDir.appendingPathComponent(id + ".json")

        if let data = try? Data(contentsOf: entryURL),
           let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) {
            let audioURL = cacheDir.appendingPathComponent(id + "." + entry.ext)
            if let audio = try? Self.decode(audioURL, marks: entry.marks, format: format) { return audio }
        }

        var body: [String: Any] = ["input": text, "voice_id": voice, "audio_format": "mp3"]
        if let model { body["model"] = model }
        // Not cached: wait our turn (one request at a time, spaced out).
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        var data: Data
        do {
            data = try await send("/v1/audio/speech", method: "POST",
                                  body: JSONSerialization.data(withJSONObject: body), key: key)
        } catch SpeechifyError.http(let code, _) where model != nil && (code == 400 || code == 422) {
            // The voice doesn't take that model: let the API pick.
            body["model"] = nil
            data = try await send("/v1/audio/speech", method: "POST",
                                  body: JSONSerialization.data(withJSONObject: body), key: key)
        }
        try Task.checkCancellation()

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = (obj["audio_data"] ?? obj["audioData"]) as? String,
              let audioData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              !audioData.isEmpty else { throw SpeechifyError.badResponse }
        let ext = ((obj["audio_format"] ?? obj["audioFormat"]) as? String).map { $0.lowercased() } ?? "mp3"
        let marks = Self.parseMarks(obj["speech_marks"] ?? obj["speechMarks"])

        let audioURL = cacheDir.appendingPathComponent(id + "." + ext)
        try audioData.write(to: audioURL, options: .atomic)
        if let entry = try? JSONEncoder().encode(CacheEntry(ext: ext, marks: marks)) {
            try? entry.write(to: entryURL, options: .atomic)
        }
        return try Self.decode(audioURL, marks: marks, format: format)
    }

    // MARK: Networking

    private func send(_ path: String, method: String, body: Data?, key: String) async throws -> Data {
        guard !key.isEmpty else { throw SpeechifyError.noKey }
        var lastError: Error = SpeechifyError.badResponse
        for attempt in 0..<Self.hosts.count {
            let index = (hostIndex + attempt) % Self.hosts.count
            guard let url = URL(string: Self.hosts[index] + path) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            do {
                var (data, response) = try await session.data(for: request)
                // Rate limited or a server hiccup: wait as long as Speechify asks (or 1, 2,
                // 4, 8 s) and try again, a few times, before giving up.
                var retry = 0
                while let http = response as? HTTPURLResponse, http.statusCode == 429 || http.statusCode >= 500,
                      retry < 4 {
                    let asked = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
                    let delay = min(asked ?? pow(2, Double(retry)), 10)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    (data, response) = try await session.data(for: request)
                    retry += 1
                }
                hostIndex = index
                guard let http = response as? HTTPURLResponse else { throw SpeechifyError.badResponse }
                guard (200..<300).contains(http.statusCode) else {
                    throw SpeechifyError.http(http.statusCode, Self.message(from: data))
                }
                return data
            } catch let error as URLError
                where [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code) {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private static func message(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        for key in ["message", "detail", "error"] {
            if let s = obj[key] as? String { return s }
            if let d = obj[key] as? [String: Any], let s = d["message"] as? String { return s }
        }
        return ""
    }

    // MARK: Parsing / decoding

    /// Collects word timestamps from the nested `speech_marks` tree
    /// (start/end: character indices in the input; start_time/end_time: milliseconds).
    static func parseMarks(_ any: Any?) -> [WordMark] {
        var out: [WordMark] = []
        func number(_ v: Any?) -> Double? {
            (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
        }
        func walk(_ v: Any?) {
            if let array = v as? [Any] {
                for element in array { walk(element) }
                return
            }
            guard let d = v as? [String: Any] else { return }
            if let chunks = d["chunks"] as? [Any], !chunks.isEmpty {
                walk(chunks)
                return
            }
            guard let start = number(d["start"]), let startMs = number(d["start_time"] ?? d["startTime"]) else { return }
            let end = number(d["end"]) ?? start
            let endMs = number(d["end_time"] ?? d["endTime"]) ?? startMs
            out.append(WordMark(start: Int(start), end: Int(end), startMs: startMs, endMs: endMs))
        }
        walk(any)
        return out.sorted { $0.startMs < $1.startMs }
    }

    /// Decodes the clip and converts it to the player's format.
    static func decode(_ url: URL, marks: [WordMark], format: AVAudioFormat) throws -> SpeechifyAudio {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let raw = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(max(file.length, 1))) else {
            throw SpeechifyError.badAudio
        }
        try file.read(into: raw)

        let buffer: AVAudioPCMBuffer
        if source.sampleRate == format.sampleRate, source.channelCount == format.channelCount,
           source.commonFormat == format.commonFormat, source.isInterleaved == format.isInterleaved {
            buffer = raw
        } else {
            guard let converter = AVAudioConverter(from: source, to: format),
                  let out = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(Double(raw.frameLength) * format.sampleRate / source.sampleRate) + 4096)
            else { throw SpeechifyError.badAudio }
            var fed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if fed {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                inputStatus.pointee = .haveData
                return raw
            }
            if status == .error { throw error ?? SpeechifyError.badAudio }
            buffer = out
        }
        guard buffer.frameLength > 0 else { throw SpeechifyError.badAudio }
        let duration = Double(buffer.frameLength) / format.sampleRate * 1000
        return SpeechifyAudio(buffer: buffer, marks: marks, durationMs: duration)
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Keeps the clip cache under `maxBytes`, dropping the oldest clips first.
    private static func prune(_ dir: URL, maxBytes: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = files.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        entries.sort { $0.date < $1.date }
        for e in entries where total > maxBytes {
            try? FileManager.default.removeItem(at: e.url)
            total -= e.size
        }
    }
}
