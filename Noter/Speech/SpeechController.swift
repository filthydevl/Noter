import AVFoundation
import UIKit

/// Which voices read aloud.
enum VoiceEngine: String, CaseIterable, Identifiable {
    /// Speechify's AI voices (needs your API key and an internet connection).
    case speechify
    /// Apple's on-device voices.
    case apple

    var id: String { rawValue }
    var title: String {
        switch self {
        case .speechify: "Speechify AI voices"
        case .apple: "Built-in voices"
        }
    }
}

/// Read-aloud with Speechify's AI voices (see `SpeechifyPlayer`) or Apple's on-device
/// voices (Premium / Enhanced when installed). If Speechify can't be reached, reading
/// carries on with the built-in voice from the same word.
/// The Apple path speaks one book page per utterance, queues the next page ahead of
/// time, and reports the word being spoken so both views can follow along line by line.
@MainActor
final class SpeechController: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var voices: [AVSpeechSynthesisVoice] = []
    @Published var speed: Double {
        didSet {
            UserDefaults.standard.set(speed, forKey: Self.speedKey)
            guard isActive, oldValue != speed else { return }
            // Speechify changes speed on the device, instantly; Apple re-queues.
            if usingSpeechify { speechify.setSpeed(speed) } else { restart() }
        }
    }
    @Published var voiceID: String {
        didSet {
            UserDefaults.standard.set(voiceID, forKey: Self.voiceKey)
            if isActive, !usingSpeechify, oldValue != voiceID { restart() }
        }
    }

    /// Experimental: let VoiceOver's speech settings (its voice, e.g. a Siri voice, and
    /// its rate) take over while VoiceOver is running. Apple only applies these settings
    /// while an assistive technology is active; otherwise the voice picked here is used.
    @Published var followVoiceOver: Bool {
        didSet {
            UserDefaults.standard.set(followVoiceOver, forKey: Self.followVoiceOverKey)
            if isActive, !usingSpeechify, oldValue != followVoiceOver { restart() }
        }
    }
    @Published private(set) var voiceOverRunning = UIAccessibility.isVoiceOverRunning
    /// What not to read aloud (headers, footnotes, citations…).
    @Published var skip: SkipOptions {
        didSet {
            guard oldValue != skip else { return }
            UserDefaults.standard.set(skip.rawValue, forKey: Self.skipKey)
            session?.skipOptionsChanged()
            if isActive { restart() }
        }
    }

    // MARK: Speechify state

    @Published var voiceEngine: VoiceEngine {
        didSet {
            guard oldValue != voiceEngine else { return }
            UserDefaults.standard.set(voiceEngine.rawValue, forKey: Self.engineKey)
            if isActive { restart() }
        }
    }
    @Published private(set) var speechifyVoices: [SpeechifyVoice] = []
    @Published private(set) var speechifyVoiceID: String
    @Published private(set) var hasSpeechifyKey = false
    /// Last problem talking to Speechify, shown in its settings.
    @Published private(set) var speechifyProblem: String?
    /// Reading right now with Speechify (false: Apple voice, including fallback).
    @Published private(set) var usingSpeechify = false

    private var speechifyKey: String?
    private lazy var speechify: SpeechifyPlayer = {
        let p = SpeechifyPlayer()
        p.host = self
        return p
    }()
    private var previewPlayer: AVPlayer?
    private var voicesFetchedAt: Date?

    weak var session: DocumentSession?

    static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    private static let speedKey = "noter.speechSpeed"
    private static let voiceKey = "noter.voice"
    /// Set once you pick a voice yourself; until then Noter always uses the best one installed.
    private static let voiceChosenKey = "noter.voiceChosen"
    /// (v2: on by default.)
    private static let followVoiceOverKey = "noter.followVoiceOver.v2"
    private static let skipKey = "noter.skip"
    private static let engineKey = "noter.voiceEngine"
    fileprivate static let speechifyVoiceKeyName = "noter.speechifyVoice"
    fileprivate static let speechifyVoicesKeyName = "noter.speechifyVoices"
    fileprivate static let speechifyKeyAccountName = "speechify-api-key"

    private let synth = AVSpeechSynthesizer()
    private struct Chunk {
        let utterance: AVSpeechUtterance
        let slot: SlotKey
        /// Maps positions in the spoken string back to the page text.
        let map: SpokenMap
    }

    /// The spoken string is the page text minus skipped parts; each segment is a run
    /// of page text copied verbatim (UTF-16 offsets).
    struct SpokenMap {
        struct Segment {
            let spoken: Int
            let text: Int
            let length: Int
        }
        var segments: [Segment] = []

        func textOffset(forSpoken offset: Int) -> Int? {
            for s in segments where offset < s.spoken + s.length {
                return offset >= s.spoken ? s.text + (offset - s.spoken) : s.text
            }
            return nil
        }
    }
    private var chunks: [ObjectIdentifier: Chunk] = [:]
    private var lastQueued: SlotKey?
    private var position: SpeechPosition?
    private var generation = 0
    private var fetching = 0

    override init() {
        let defaults = UserDefaults.standard
        speed = defaults.object(forKey: Self.speedKey) as? Double ?? 1.0
        voiceID = defaults.string(forKey: Self.voiceKey) ?? ""
        followVoiceOver = defaults.object(forKey: Self.followVoiceOverKey) as? Bool ?? true
        skip = (defaults.object(forKey: Self.skipKey) as? Int).map(SkipOptions.init(rawValue:)) ?? .defaults
        voiceEngine = defaults.string(forKey: Self.engineKey).flatMap(VoiceEngine.init(rawValue:)) ?? .speechify
        speechifyVoiceID = defaults.string(forKey: Self.speechifyVoiceKeyName) ?? ""
        super.init()
        speechifyKey = Keychain.string(Self.speechifyKeyAccountName)
        hasSpeechifyKey = !(speechifyKey ?? "").isEmpty
        if let data = defaults.data(forKey: Self.speechifyVoicesKeyName),
           let cached = try? JSONDecoder().decode([SpeechifyVoice].self, from: data) {
            speechifyVoices = cached
        }
        synth.delegate = self
        refreshVoices()
        // Newly downloaded voices show up without restarting the app.
        NotificationCenter.default.addObserver(
            self, selector: #selector(availableVoicesChanged),
            name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(voiceOverStatusChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
    }

    /// The setting is read when an utterance starts, so when VoiceOver is switched on or
    /// off mid-page, re-queue from the current word to switch voices right away.
    @objc nonisolated private func voiceOverStatusChanged() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let running = UIAccessibility.isVoiceOverRunning
            guard running != self.voiceOverRunning else { return }
            self.voiceOverRunning = running
            // Turning VoiceOver on means you want its voice.
            if running, !self.followVoiceOver {
                self.followVoiceOver = true
                return // its didSet already re-queued the reading
            }
            guard self.followVoiceOver, self.isActive, !self.usingSpeechify else { return }
            if self.isPlaying {
                self.restart()
            } else {
                // Paused: drop the paused utterance so ▶ restarts from the current word
                // with the new voice.
                self.generation += 1
                self.chunks.removeAll()
                if self.synth.isSpeaking || self.synth.isPaused { self.synth.stopSpeaking(at: .immediate) }
            }
        }
    }

    @objc nonisolated private func availableVoicesChanged() {
        Task { @MainActor [weak self] in self?.refreshVoices() }
    }

    // MARK: Voices

    /// Natural-sounding voices only (Premium, then Enhanced) in your language; the basic
    /// compact voices are listed only when no natural voice is installed.
    func refreshVoices() {
        let language = String((Locale.preferredLanguages.first ?? "en").prefix(2))
        let region = AVSpeechSynthesisVoice.currentLanguageCode()
        let usable = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let matching = usable.filter { $0.language.hasPrefix(language) }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            let quality: Int
            switch v.quality {
            case .premium: quality = 30
            case .enhanced: quality = 20
            default: quality = 10
            }
            return quality + (v.language == region ? 1 : 0)
        }
        let ranked = (matching.isEmpty ? usable : matching).sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra > rb : a.name < b.name
        }
        let natural = ranked.filter { $0.quality == .premium || $0.quality == .enhanced }
        voices = natural.isEmpty ? ranked : natural

        let chosen = UserDefaults.standard.bool(forKey: Self.voiceChosenKey)
        if !chosen || !voices.contains(where: { $0.identifier == voiceID }) {
            let best = voices.first?.identifier ?? ""
            if best != voiceID { voiceID = best }
        }
    }

    var hasNaturalVoice: Bool {
        voices.contains { $0.quality == .premium || $0.quality == .enhanced }
    }

    struct VoiceSection {
        let title: String
        let voices: [AVSpeechSynthesisVoice]
    }

    var voiceSections: [VoiceSection] {
        let premium = voices.filter { $0.quality == .premium }
        let enhanced = voices.filter { $0.quality == .enhanced }
        let other = voices.filter { $0.quality != .premium && $0.quality != .enhanced }
        return [
            VoiceSection(title: "Premium", voices: premium),
            VoiceSection(title: "Enhanced", voices: enhanced),
            VoiceSection(title: "Standard", voices: other),
        ].filter { !$0.voices.isEmpty }
    }

    /// "Ava · US"
    static func voiceTitle(_ v: AVSpeechSynthesisVoice) -> String {
        let region = v.language.split(separator: "-").last.map(String.init) ?? v.language
        return "\(v.name) · \(region)"
    }

    /// Picks a voice from the menu. When nothing is being read, plays a short sample.
    func chooseVoice(_ id: String) {
        UserDefaults.standard.set(true, forKey: Self.voiceChosenKey)
        voiceID = id
        guard !isActive, let v = AVSpeechSynthesisVoice(identifier: id) else { return }
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        activateAudio()
        let sample = AVSpeechUtterance(string: "Hi, I'm \(v.name). This is how I'll read to you.")
        sample.voice = v
        sample.rate = rate
        sample.prefersAssistiveTechnologySettings = followVoiceOver
        synth.speak(sample) // not a page chunk, so the delegate ignores it
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Standard"
        }
    }

    /// AVSpeech rates aren't linear: 0.5 is normal speed and 1.0 is roughly 4×, so each
    /// doubling of the speed adds a quarter.
    private var rate: Float {
        let r = AVSpeechUtteranceDefaultSpeechRate + 0.25 * Float(log2(max(speed, 0.25)))
        return min(max(r, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    // MARK: Transport

    func togglePlay() {
        if !isActive {
            guard let s = session else { return }
            play(from: s.readingStartSlot(), token: 0)
        } else if isPlaying {
            if usingSpeechify { speechify.pause() } else { synth.pauseSpeaking(at: .word) }
            isPlaying = false
        } else {
            activateAudio()
            if usingSpeechify {
                do { try speechify.resume() } catch { restart() }
            } else if synth.isPaused {
                synth.continueSpeaking()
            } else {
                restart()
            }
            isPlaying = true
        }
    }

    func play(from slot: SlotKey, token: Int) {
        if speechifyReady {
            playSpeechify(from: slot, token: token)
        } else if voiceEngine == .speechify, hasSpeechifyKey, speechifyVoiceID.isEmpty {
            // Key saved but no voice picked yet: fetch the voices first (once).
            isActive = true
            isPlaying = true
            isLoading = true
            Task { [weak self] in
                guard let self else { return }
                await self.refreshSpeechifyVoices()
                guard self.isActive else { return }
                if self.speechifyReady {
                    self.playSpeechify(from: slot, token: token)
                } else {
                    self.playApple(from: slot, token: token)
                }
            }
        } else {
            playApple(from: slot, token: token)
        }
    }

    private var speechifyReady: Bool {
        voiceEngine == .speechify && hasSpeechifyKey && !speechifyVoiceID.isEmpty
    }

    private func stopApple() {
        generation += 1
        chunks.removeAll()
        lastQueued = nil
        fetching = 0
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
    }

    private func playApple(from slot: SlotKey, token: Int) {
        speechify.stop()
        usingSpeechify = false
        isLoading = false
        stopApple()
        activateAudio()
        isActive = true
        isPlaying = true
        queue(slot, token: token)
    }

    private func playSpeechify(from slot: SlotKey, token: Int) {
        stopApple()
        previewPlayer?.pause()
        activateAudio()
        let voice = speechifyVoices.first { $0.id == speechifyVoiceID }
        usingSpeechify = true
        isActive = true
        isPlaying = true
        do {
            try speechify.start(slot: slot, token: token, voice: speechifyVoiceID, model: voice?.bestModel,
                                key: speechifyKey ?? "", speed: speed)
        } catch {
            playApple(from: slot, token: token)
        }
    }

    func stop() {
        stopApple()
        speechify.stop()
        usingSpeechify = false
        finish()
    }

    func restart() {
        if let p = position {
            play(from: p.slot, token: p.token)
        } else if let s = session {
            play(from: s.readingStartSlot(), token: 0)
        }
    }

    private func finish() {
        isActive = false
        isPlaying = false
        isLoading = false
        position = nil
        session?.speechMoved(nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func activateAudio() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: [])
        try? audio.setActive(true)
    }

    // MARK: Queue

    func nextSlot(after slot: SlotKey) -> SlotKey? {
        guard let s = session else { return nil }
        if slot.half + 1 < s.halfCount(slot.pdfIndex) { return SlotKey(pdfIndex: slot.pdfIndex, half: slot.half + 1) }
        if slot.pdfIndex + 1 < s.pageCount { return SlotKey(pdfIndex: slot.pdfIndex + 1, half: 0) }
        return nil
    }

    private func queue(_ slot: SlotKey, token: Int) {
        guard let s = session else { return }
        lastQueued = slot
        if let lp = s.logicalPage(slot) {
            speak(lp, token: token)
            return
        }
        // Page not recognised yet (or the half doesn't exist): read it first.
        let gen = generation
        fetching += 1
        isLoading = chunks.isEmpty
        Task { [weak self] in
            _ = await s.ocr.ensure(slot.pdfIndex)
            guard let self, gen == self.generation else { return }
            self.fetching -= 1
            self.isLoading = false
            if let lp = s.logicalPage(slot) {
                self.speak(lp, token: token)
            } else if let n = self.nextSlot(after: slot) {
                self.queue(n, token: 0)
            } else if self.chunks.isEmpty {
                self.finish()
            }
        }
    }

    /// The page text from `token` on, leaving out skipped ranges, plus the map from
    /// positions in that string back to the page text.
    func spokenText(_ lp: LogicalPage, fromToken token: Int) -> (text: String, map: SpokenMap) {
        let ns = lp.text as NSString
        let start = token < lp.tokenRanges.count ? lp.tokenRanges[max(token, 0)].location : ns.length
        let spoken = NSMutableString()
        var map = SpokenMap()
        func copy(_ from: Int, _ to: Int) {
            guard to > from else { return }
            map.segments.append(.init(spoken: spoken.length, text: from, length: to - from))
            spoken.append(ns.substring(with: NSRange(location: from, length: to - from)))
        }
        var cursor = start
        for r in SkipFilter.excludedRanges(in: lp, options: skip) where NSMaxRange(r) > cursor {
            copy(cursor, max(cursor, r.location))
            spoken.append(" ")
            cursor = max(cursor, NSMaxRange(r))
        }
        copy(cursor, ns.length)
        return (spoken as String, map)
    }

    private func speak(_ lp: LogicalPage, token: Int) {
        let (text, map) = spokenText(lp, fromToken: token)
        lastQueued = lp.slot
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Blank page — move on.
            if let n = nextSlot(after: lp.slot) {
                queue(n, token: 0)
            } else if chunks.isEmpty && fetching == 0 {
                finish()
            }
            return
        }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? voices.first
        u.rate = rate
        u.postUtteranceDelay = 0.15
        u.prefersAssistiveTechnologySettings = followVoiceOver
        chunks[ObjectIdentifier(u)] = Chunk(utterance: u, slot: lp.slot, map: map)
        synth.speak(u)
    }

    // MARK: Delegate (main actor)

    fileprivate func didStart(_ id: ObjectIdentifier) {
        guard let c = chunks[id] else { return }
        isLoading = false
        // Queue the next page while this one is being read, so there's no pause.
        if lastQueued == c.slot, let n = nextSlot(after: c.slot) { queue(n, token: 0) }
    }

    fileprivate func willSpeak(_ id: ObjectIdentifier, range: NSRange) {
        guard let c = chunks[id], let lp = session?.logicalPage(c.slot),
              let offset = c.map.textOffset(forSpoken: range.location),
              let token = lp.tokenIndex(atUTF16: offset) else { return }
        let p = SpeechPosition(pdfIndex: c.slot.pdfIndex, half: c.slot.half, token: token)
        guard p != position else { return }
        position = p
        session?.speechMoved(p)
    }

    fileprivate func didFinish(_ id: ObjectIdentifier) {
        guard chunks.removeValue(forKey: id) != nil else { return }
        guard chunks.isEmpty, fetching == 0, isActive else { return }
        // Nothing left in the queue: continue with the following page, or stop at the end.
        if let n = lastQueued.flatMap({ nextSlot(after: $0) }) {
            queue(n, token: 0)
        } else {
            finish()
        }
    }
}

// MARK: - Speechify

extension SpeechController {
    // MARK: Player callbacks

    /// The book page, recognizing its text first if needed.
    func page(for slot: SlotKey) async -> LogicalPage? {
        guard let s = session else { return nil }
        if let lp = s.logicalPage(slot) { return lp }
        _ = await s.ocr.ensure(slot.pdfIndex)
        return s.logicalPage(slot)
    }

    func speechifyMoved(slot: SlotKey, textOffset: Int) {
        guard usingSpeechify, let lp = session?.logicalPage(slot),
              let token = lp.tokenIndex(atUTF16: textOffset) else { return }
        let p = SpeechPosition(pdfIndex: slot.pdfIndex, half: slot.half, token: token)
        guard p != position else { return }
        position = p
        session?.speechMoved(p)
    }

    func speechifyLoading(_ loading: Bool) {
        guard usingSpeechify, isLoading != loading else { return }
        isLoading = loading
    }

    func speechifyFinished() {
        usingSpeechify = false
        finish()
    }

    func speechifyNeedsRestart() {
        if isActive, usingSpeechify { restart() }
    }

    /// Speechify couldn't be reached (or refused): keep reading with the built-in
    /// voice from the same word, so reading never just stops.
    func speechifyFailed(_ error: Error, slot: SlotKey, textOffset: Int?) {
        guard usingSpeechify else { return }
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        speechifyProblem = (error as? SpeechifyError)?.isAuthProblem == true
            ? "Your API key was rejected. Paste it again below."
            : "Last error: \(reason)."
        session?.showToast("Speechify: \(reason). Reading with the built-in voice.")
        var from = SlotKey(pdfIndex: slot.pdfIndex, half: slot.half)
        var token = 0
        if let p = position {
            from = p.slot
            token = p.token
        } else if let offset = textOffset, let lp = session?.logicalPage(slot),
                  let t = lp.tokenIndex(atUTF16: offset) {
            token = t
        }
        playApple(from: from, token: token)
    }

    // MARK: Key and voices

    /// Saves the API key (in the Keychain) after checking it with Speechify.
    /// Returns a message to show, or nil when everything worked.
    func saveSpeechifyKey(_ raw: String) async -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Paste your API key first." }
        do {
            let voices = try await SpeechifyClient.shared.voices(key: key)
            storeKey(key)
            setSpeechifyVoices(voices)
            return nil
        } catch let error as SpeechifyError where error.isAuthProblem {
            return "Speechify rejected this key. Check it and try again."
        } catch {
            // Offline or Speechify unreachable: keep the key and check it later.
            storeKey(key)
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return "Saved, but couldn't reach Speechify to check it (\(reason))."
        }
    }

    private func storeKey(_ key: String) {
        Keychain.set(key, Self.speechifyKeyAccountName)
        speechifyKey = key
        hasSpeechifyKey = true
        speechifyProblem = nil
        if voiceEngine != .speechify { voiceEngine = .speechify }
    }

    func removeSpeechifyKey() {
        if usingSpeechify { stop() }
        Keychain.set(nil, Self.speechifyKeyAccountName)
        speechifyKey = nil
        hasSpeechifyKey = false
    }

    /// Loads the voice list (at most hourly unless forced). Also warms up the
    /// connection, so the first clip arrives faster when you press play.
    func refreshSpeechifyVoices(force: Bool = false) async {
        guard let key = speechifyKey, !key.isEmpty else { return }
        if !force, let fetched = voicesFetchedAt, Date().timeIntervalSince(fetched) < 3600, !speechifyVoices.isEmpty {
            return
        }
        do {
            setSpeechifyVoices(try await SpeechifyClient.shared.voices(key: key))
            speechifyProblem = nil
        } catch {
            if (error as? SpeechifyError)?.isAuthProblem == true {
                speechifyProblem = "Your API key was rejected. Paste it again below."
            }
        }
    }

    func warmUpSpeechify() {
        guard voiceEngine == .speechify, hasSpeechifyKey else { return }
        Task { await refreshSpeechifyVoices() }
    }

    private func setSpeechifyVoices(_ voices: [SpeechifyVoice]) {
        voicesFetchedAt = Date()
        let language = String((Locale.preferredLanguages.first ?? "en").prefix(2))
        let sorted = voices.sorted { a, b in
            let la = a.locale.hasPrefix(language), lb = b.locale.hasPrefix(language)
            if la != lb { return la }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        speechifyVoices = sorted
        if let data = try? JSONEncoder().encode(sorted) {
            UserDefaults.standard.set(data, forKey: Self.speechifyVoicesKeyName)
        }
        if speechifyVoiceID.isEmpty || !sorted.contains(where: { $0.id == speechifyVoiceID }) {
            let favorites = ["george", "henry", "carly", "kristy", "oliver"]
            let pick = favorites.lazy.compactMap { id in sorted.first { $0.id.lowercased() == id } }.first
                ?? sorted.first { $0.locale.hasPrefix(language) }
                ?? sorted.first
            setSpeechifyVoice(pick?.id ?? "")
        }
    }

    private func setSpeechifyVoice(_ id: String) {
        speechifyVoiceID = id
        UserDefaults.standard.set(id, forKey: Self.speechifyVoiceKeyName)
    }

    /// Voices in your language (all voices if none match).
    var speechifyLanguageVoices: [SpeechifyVoice] {
        let language = String((Locale.preferredLanguages.first ?? "en").prefix(2))
        let matching = speechifyVoices.filter { $0.locale.hasPrefix(language) }
        return matching.isEmpty ? speechifyVoices : matching
    }

    var currentSpeechifyVoice: SpeechifyVoice? {
        speechifyVoices.first { $0.id == speechifyVoiceID }
    }

    /// Picks a Speechify voice. While reading, switches from the current word;
    /// otherwise plays the voice's free preview clip.
    func chooseSpeechifyVoice(_ id: String) {
        let changed = id != speechifyVoiceID
        setSpeechifyVoice(id)
        if voiceEngine != .speechify {
            voiceEngine = .speechify // its didSet restarts reading if needed
            if !isActive { playPreview(id) }
            return
        }
        if isActive {
            if changed, usingSpeechify { restart() }
        } else {
            playPreview(id)
        }
    }

    func playPreview(_ id: String) {
        guard !isActive, let link = speechifyVoices.first(where: { $0.id == id })?.preview,
              let url = URL(string: link) else { return }
        activateAudio()
        previewPlayer = AVPlayer(url: url)
        previewPlayer?.play()
    }
}

extension SpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.didStart(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.willSpeak(id, range: characterRange) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.didFinish(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.didFinish(id) }
    }
}
