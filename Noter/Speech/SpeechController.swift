import AVFoundation
import UIKit

/// Read-aloud using Apple's on-device voices (Premium / Enhanced "neural" voices when
/// installed). Speaks one book page per utterance, queues the next page ahead of time,
/// and reports the word being spoken so both views can follow along line by line.
@MainActor
final class SpeechController: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var voices: [AVSpeechSynthesisVoice] = []
    @Published var speed: Double {
        didSet {
            UserDefaults.standard.set(speed, forKey: Self.speedKey)
            guard oldValue != speed else { return }
            if useAssistive {
                session?.showToast("VoiceOver sets the speed of its voice (rotor › Speaking Rate)")
            }
            if isActive { restart() }
        }
    }
    @Published var voiceID: String {
        didSet {
            UserDefaults.standard.set(voiceID, forKey: Self.voiceKey)
            if isActive, oldValue != voiceID { restart() }
        }
    }

    /// Experimental: let VoiceOver's speech settings (its voice, e.g. a Siri voice, and
    /// its rate) take over while VoiceOver is running. Apple only applies these settings
    /// while an assistive technology is active; otherwise the voice picked here is used.
    @Published var followVoiceOver: Bool {
        didSet {
            UserDefaults.standard.set(followVoiceOver, forKey: Self.followVoiceOverKey)
            if isActive, oldValue != followVoiceOver { restart() }
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

    weak var session: DocumentSession?

    static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    private static let speedKey = "noter.speechSpeed"
    private static let voiceKey = "noter.voice"
    /// Set once you pick a voice yourself; until then Noter always uses the best one installed.
    private static let voiceChosenKey = "noter.voiceChosen"
    /// (v2: on by default.)
    private static let followVoiceOverKey = "noter.followVoiceOver.v2"
    private static let skipKey = "noter.skip"

    private var synth = AVSpeechSynthesizer()
    private struct Chunk {
        let utterance: AVSpeechUtterance
        let slot: SlotKey
        /// The word reading started at.
        let token: Int
        /// Maps positions in the spoken string back to the page text.
        let map: SpokenMap
        /// Read with VoiceOver's voice settings.
        let assistive: Bool
        var started = false
        var spokeWord = false
    }

    /// The spoken string is the page text minus skipped parts; each segment is a run
    /// of page text copied verbatim (UTF-16 offsets).
    private struct SpokenMap {
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
    /// VoiceOver's voice (e.g. a Siri voice) turned out to be off-limits to apps: it
    /// produced no audio, so Noter reads with its own voice for the rest of the session.
    private var assistiveFailed = false
    /// The synthesizer was replaced once already because it never started speaking.
    private var resetSynth = false

    /// VoiceOver's settings only apply while VoiceOver is running. With it off, asking
    /// for them makes iOS hand the utterance to the Spoken Content voice — often a Siri
    /// voice apps aren't allowed to use — and nothing is heard. So only ask while it's on.
    private var useAssistive: Bool {
        followVoiceOver && UIAccessibility.isVoiceOverRunning && !assistiveFailed
    }

    override init() {
        let defaults = UserDefaults.standard
        speed = defaults.object(forKey: Self.speedKey) as? Double ?? 1.0
        voiceID = defaults.string(forKey: Self.voiceKey) ?? ""
        followVoiceOver = defaults.object(forKey: Self.followVoiceOverKey) as? Bool ?? true
        skip = (defaults.object(forKey: Self.skipKey) as? Int).map(SkipOptions.init(rawValue:)) ?? .defaults
        super.init()
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
            guard self.followVoiceOver, self.isActive else { return }
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
        sample.prefersAssistiveTechnologySettings = useAssistive
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
            synth.pauseSpeaking(at: .word)
            isPlaying = false
        } else {
            activateAudio()
            if synth.isPaused { synth.continueSpeaking() } else { restart() }
            isPlaying = true
        }
    }

    func play(from slot: SlotKey, token: Int) {
        generation += 1
        chunks.removeAll()
        lastQueued = nil
        fetching = 0
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        activateAudio()
        isActive = true
        isPlaying = true
        queue(slot, token: token)
    }

    func stop() {
        generation += 1
        chunks.removeAll()
        fetching = 0
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        finish()
    }

    private func restart() {
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

    private func next(after slot: SlotKey) -> SlotKey? {
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
            } else if let n = self.next(after: slot) {
                self.queue(n, token: 0)
            } else if self.chunks.isEmpty {
                self.finish()
            }
        }
    }

    private func speak(_ lp: LogicalPage, token: Int) {
        let ns = lp.text as NSString
        let start = token < lp.tokenRanges.count ? lp.tokenRanges[max(token, 0)].location : ns.length
        // Copy the page text from `start`, leaving out skipped ranges.
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
        let text = spoken as String
        lastQueued = lp.slot
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Blank page — move on.
            if let n = next(after: lp.slot) {
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
        let assistive = useAssistive
        u.prefersAssistiveTechnologySettings = assistive
        let id = ObjectIdentifier(u)
        chunks[id] = Chunk(utterance: u, slot: lp.slot, token: token, map: map, assistive: assistive)
        synth.speak(u)
        watchStart(id)
    }

    // MARK: Watchdog

    /// If the first page queued never starts speaking, the voice is unusable (or the
    /// synthesizer is stuck): switch to Noter's own voice / a fresh synthesizer and go on.
    private func watchStart(_ id: ObjectIdentifier) {
        let gen = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, gen == self.generation, self.isPlaying,
                  let c = self.chunks[id], !c.started,
                  !self.chunks.values.contains(where: { $0.started }) else { return }
            self.recover(from: c)
        }
    }

    private func recover(from c: Chunk) {
        if c.assistive {
            assistiveFailed = true
            session?.showToast("VoiceOver's voice isn't available to apps — reading with \(currentVoiceName)")
        } else if !resetSynth {
            resetSynth = true
            synth.delegate = nil
            synth.stopSpeaking(at: .immediate)
            synth = AVSpeechSynthesizer()
            synth.delegate = self
        } else {
            session?.showToast("Couldn't start the voice. Try another voice from the speed menu.")
            stop()
            return
        }
        play(from: c.slot, token: c.token)
    }

    private var currentVoiceName: String {
        (AVSpeechSynthesisVoice(identifier: voiceID) ?? voices.first)?.name ?? "the selected voice"
    }

    // MARK: Delegate (main actor)

    fileprivate func didStart(_ id: ObjectIdentifier) {
        guard let c = chunks[id] else { return }
        chunks[id]?.started = true
        isLoading = false
        // Queue the next page while this one is being read, so there's no pause.
        if lastQueued == c.slot, let n = next(after: c.slot) { queue(n, token: 0) }
    }

    fileprivate func willSpeak(_ id: ObjectIdentifier, range: NSRange) {
        chunks[id]?.spokeWord = true
        guard let c = chunks[id], let lp = session?.logicalPage(c.slot),
              let offset = c.map.textOffset(forSpoken: range.location),
              let token = lp.tokenIndex(atUTF16: offset) else { return }
        let p = SpeechPosition(pdfIndex: c.slot.pdfIndex, half: c.slot.half, token: token)
        guard p != position else { return }
        position = p
        session?.speechMoved(p)
    }

    fileprivate func didFinish(_ id: ObjectIdentifier, cancelled: Bool) {
        guard let c = chunks.removeValue(forKey: id) else { return }
        // A whole page "read" without a single word: the voice made no sound (VoiceOver's
        // Siri voice does this for apps). Read it again with Noter's own voice.
        if !cancelled, c.assistive, !c.spokeWord, isActive {
            recover(from: c)
            return
        }
        guard chunks.isEmpty, fetching == 0, isActive else { return }
        // Nothing left in the queue: continue with the following page, or stop at the end.
        if let n = lastQueued.flatMap({ next(after: $0) }) {
            queue(n, token: 0)
        } else {
            finish()
        }
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
        Task { @MainActor [weak self] in self?.didFinish(id, cancelled: false) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.didFinish(id, cancelled: true) }
    }
}
