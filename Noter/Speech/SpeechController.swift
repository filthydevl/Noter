import AVFoundation

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
            if isActive, oldValue != speed { restart() }
        }
    }
    @Published var voiceID: String {
        didSet {
            UserDefaults.standard.set(voiceID, forKey: Self.voiceKey)
            if isActive, oldValue != voiceID { restart() }
        }
    }

    weak var session: DocumentSession?

    static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    private static let speedKey = "noter.speechSpeed"
    private static let voiceKey = "noter.voice"

    private let synth = AVSpeechSynthesizer()
    private struct Chunk {
        let utterance: AVSpeechUtterance
        let slot: SlotKey
        /// UTF-16 offset of the utterance's first character in the page text.
        let offset: Int
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
        super.init()
        synth.delegate = self
        refreshVoices()
        if voiceID.isEmpty || AVSpeechSynthesisVoice(identifier: voiceID) == nil {
            voiceID = voices.first?.identifier ?? ""
        }
    }

    // MARK: Voices

    /// Best voices first: Premium, then Enhanced, then the rest, preferring your language.
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
        voices = (matching.isEmpty ? usable : matching).sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra > rb : a.name < b.name
        }
    }

    var hasNaturalVoice: Bool {
        voices.contains { $0.quality == .premium || $0.quality == .enhanced }
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Standard"
        }
    }

    private var rate: Float {
        let r = AVSpeechUtteranceDefaultSpeechRate + Float(speed - 1) * 0.18
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
        let text = ns.substring(from: start)
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
        u.prefersAssistiveTechnologySettings = false
        chunks[ObjectIdentifier(u)] = Chunk(utterance: u, slot: lp.slot, offset: start)
        synth.speak(u)
    }

    // MARK: Delegate (main actor)

    fileprivate func didStart(_ id: ObjectIdentifier) {
        guard let c = chunks[id] else { return }
        isLoading = false
        // Queue the next page while this one is being read, so there's no pause.
        if lastQueued == c.slot, let n = next(after: c.slot) { queue(n, token: 0) }
    }

    fileprivate func willSpeak(_ id: ObjectIdentifier, range: NSRange) {
        guard let c = chunks[id], let lp = session?.logicalPage(c.slot),
              let token = lp.tokenIndex(atUTF16: c.offset + range.location) else { return }
        let p = SpeechPosition(pdfIndex: c.slot.pdfIndex, half: c.slot.half, token: token)
        guard p != position else { return }
        position = p
        session?.speechMoved(p)
    }

    fileprivate func didFinish(_ id: ObjectIdentifier) {
        guard chunks.removeValue(forKey: id) != nil else { return }
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
        Task { @MainActor [weak self] in self?.didFinish(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.didFinish(id) }
    }
}
