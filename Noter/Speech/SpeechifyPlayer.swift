import AVFoundation
import Foundation

/// Plays Speechify voices without gaps or lag:
/// * the first clip is short (one sentence or so) so audio starts within a moment;
/// * while it plays, the next clips are fetched in parallel (crossing into the next
///   pages, recognizing their text first if needed) and queued back-to-back on one
///   audio player, so there's no pause between clips or pages;
/// * speed is changed on the device (pitch-corrected), instantly, without re-fetching;
/// * the word being spoken comes from Speechify's word timestamps, so the line and
///   word highlighting follow the voice exactly.
@MainActor
final class SpeechifyPlayer {
    weak var host: SpeechController?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var wired = false

    private final class Item {
        let slot: SlotKey
        let text: String
        let length: Int
        /// Where `text` starts in the page's spoken string.
        let spokenStart: Int
        let map: SpeechController.SpokenMap
        var audio: SpeechifyAudio?
        var task: Task<Void, Never>?
        var start: AVAudioFramePosition = -1
        var frames: AVAudioFramePosition = 0

        init(slot: SlotKey, text: String, spokenStart: Int, map: SpeechController.SpokenMap) {
            self.slot = slot
            self.text = text
            self.length = (text as NSString).length
            self.spokenStart = spokenStart
            self.map = map
        }
    }

    private struct Pending {
        let slot: SlotKey
        let text: NSString
        let map: SpeechController.SpokenMap
        var offset: Int
    }

    private var items: [Item] = []
    private var pending: Pending?
    private var upcoming: SlotKey?
    private var startToken = 0
    private var firstPage = true
    private var produced = 0
    private var exhausted = false
    private var filling = false
    private var scheduledEnd: AVAudioFramePosition = 0
    private var generation = 0
    private var timer: Timer?
    private var voice = ""
    private var model: String?
    private var key = ""
    /// Clips fetched ahead of the one playing.
    private let lookahead = 2

    private(set) var isPaused = false
    var isRunning: Bool { !items.isEmpty || filling }

    // MARK: Transport

    func start(slot: SlotKey, token: Int, voice: String, model: String?, key: String, speed: Double) throws {
        stop()
        self.voice = voice
        self.model = model
        self.key = key
        upcoming = slot
        startToken = token
        firstPage = true
        wire()
        setSpeed(speed)
        if !engine.isRunning { try engine.start() }
        node.play()
        isPaused = false
        startTimer()
        host?.speechifyLoading(true)
        fill()
    }

    func pause() {
        guard wired else { return }
        node.pause()
        isPaused = true
    }

    func resume() throws {
        guard wired else { return }
        if !engine.isRunning { try engine.start() }
        node.play()
        isPaused = false
    }

    /// At 1× the voice plays untouched (the time-stretch effect is bypassed: left on, it
    /// made normal speed sound robotic after a change); other speeds use the effect at
    /// its best quality.
    func setSpeed(_ speed: Double) {
        timePitch.overlap = 32 // highest quality
        timePitch.rate = Float(speed)
        timePitch.bypass = abs(speed - 1) < 0.01
    }

    func stop() {
        generation += 1
        for item in items { item.task?.cancel() }
        items.removeAll()
        pending = nil
        upcoming = nil
        exhausted = false
        filling = false
        produced = 0
        scheduledEnd = 0
        timer?.invalidate()
        timer = nil
        isPaused = false
        if wired {
            node.stop()
            engine.stop()
        }
    }

    // MARK: Pipeline

    private func wire() {
        guard !wired else { return }
        engine.attach(node)
        engine.attach(timePitch)
        engine.connect(node, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engine.prepare()
        wired = true
        // Headphones plugged / unplugged etc. stop the engine: pick up where we were.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.items.isEmpty, !self.isPaused else { return }
                self.host?.speechifyNeedsRestart()
            }
        }
    }

    /// Keeps the playing clip plus `lookahead` more requested.
    private func fill() {
        guard !filling, !exhausted else { return }
        filling = true
        let gen = generation
        Task { [weak self] in
            guard let self else { return }
            while gen == self.generation, self.items.count <= self.lookahead {
                guard let item = await self.nextChunk() else {
                    if gen == self.generation { self.exhausted = true }
                    break
                }
                guard gen == self.generation else { return }
                self.items.append(item)
                self.fetch(item, gen: gen)
            }
            guard gen == self.generation else { return }
            self.filling = false
            self.updateLoading()
            self.checkFinished()
        }
    }

    /// The next piece of text to synthesize: short at first for a fast start, then
    /// larger pieces ending at sentence boundaries.
    private func nextChunk() async -> Item? {
        let gen = generation
        while gen == generation {
            if var p = pending {
                let ns = p.text
                var o = p.offset
                while o < ns.length, Self.isSpace(ns.character(at: o)) { o += 1 }
                if o < ns.length {
                    let limit = produced == 0 ? 220 : (produced == 1 ? 700 : 1500)
                    let end = Self.cut(ns, from: o, limit: limit)
                    p.offset = end
                    pending = p
                    produced += 1
                    return Item(slot: p.slot, text: ns.substring(with: NSRange(location: o, length: end - o)),
                                spokenStart: o, map: p.map)
                }
                pending = nil
            }
            guard let slot = upcoming, let host else { return nil }
            let page = await host.page(for: slot)
            guard gen == generation else { return nil }
            if let page {
                let spoken = host.spokenText(page, fromToken: firstPage ? startToken : 0)
                pending = Pending(slot: slot, text: spoken.text as NSString, map: spoken.map, offset: 0)
            }
            firstPage = false
            upcoming = host.nextSlot(after: slot)
        }
        return nil
    }

    private func fetch(_ item: Item, gen: Int) {
        let text = item.text, voice = voice, model = model, key = key, format = format
        item.task = Task { [weak self] in
            var attempt = 0
            while true {
                do {
                    let audio = try await SpeechifyClient.shared.speech(
                        text: text, voice: voice, model: model, key: key, format: format)
                    guard let self, gen == self.generation else { return }
                    item.audio = audio
                    self.scheduleReady()
                    return
                } catch {
                    guard let self, gen == self.generation, !Task.isCancelled else { return }
                    if let e = error as? URLError, e.code == .cancelled { return }
                    // A dropped connection gets one more try before giving up.
                    if attempt == 0, error is URLError {
                        attempt += 1
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        continue
                    }
                    let offset = item.map.textOffset(forSpoken: item.spokenStart)
                    self.host?.speechifyFailed(error, slot: item.slot, textOffset: offset)
                    return
                }
            }
        }
    }

    /// Queues every clip that's ready, in order, right after the previous one.
    private func scheduleReady() {
        for item in items where item.start < 0 {
            guard let audio = item.audio else { break }
            let now = currentFrame() ?? scheduledEnd
            item.start = max(scheduledEnd, now)
            item.frames = AVAudioFramePosition(audio.buffer.frameLength)
            scheduledEnd = item.start + item.frames
            let gen = generation
            node.scheduleBuffer(audio.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in self?.played(item, gen: gen) }
            }
        }
        updateLoading()
    }

    private func played(_ item: Item, gen: Int) {
        guard gen == generation else { return }
        items.removeAll { $0 === item }
        fill()
        updateLoading()
        checkFinished()
    }

    private func updateLoading() {
        let waiting: Bool
        if let first = items.first {
            waiting = first.audio == nil
        } else {
            waiting = !exhausted
        }
        host?.speechifyLoading(waiting)
    }

    private func checkFinished() {
        guard exhausted, items.isEmpty, !filling else { return }
        stop()
        host?.speechifyFinished()
    }

    // MARK: Follow-along

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard !isPaused, let now = currentFrame(),
              let item = items.first(where: { $0.start >= 0 && now < $0.start + $0.frames }),
              now >= item.start, let audio = item.audio else { return }
        let ms = Double(now - item.start) / format.sampleRate * 1000
        let local = audio.characterOffset(atMs: ms, length: item.length)
        guard let offset = item.map.textOffset(forSpoken: item.spokenStart + local) else { return }
        host?.speechifyMoved(slot: item.slot, textOffset: offset)
    }

    private func currentFrame() -> AVAudioFramePosition? {
        guard wired, let renderTime = node.lastRenderTime, renderTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: renderTime) else { return nil }
        return playerTime.sampleTime
    }

    // MARK: Text cutting

    private static func isSpace(_ c: unichar) -> Bool {
        c == 32 || c == 10 || c == 9 || c == 13 || c == 0xA0
    }

    private static let sentenceEnds: Set<unichar> = Set(".!?;:…".utf16)

    /// End of a chunk starting at `start`: the last sentence end within `limit`
    /// characters, else the last space.
    static func cut(_ ns: NSString, from start: Int, limit: Int) -> Int {
        let hardEnd = min(ns.length, start + limit)
        if hardEnd >= ns.length { return ns.length }
        let floor = start + limit / 4
        var i = hardEnd - 1
        while i > floor {
            let c = ns.character(at: i)
            if c == 10 { return i + 1 }
            if sentenceEnds.contains(c), isSpace(ns.character(at: i + 1)) { return i + 1 }
            i -= 1
        }
        i = hardEnd - 1
        while i > start {
            if isSpace(ns.character(at: i)) { return i }
            i -= 1
        }
        return NSMaxRange(ns.rangeOfComposedCharacterSequence(at: hardEnd - 1))
    }
}
