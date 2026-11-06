import Foundation
import CoreGraphics

/// Owns the OCR results of one document.
///
/// * Pages are recognised one at a time on a background task, starting at the page you
///   are looking at, so huge PDFs are usable immediately.
/// * Every finished page is written to its own file right away; a crash or dead battery
///   loses at most the page that was in progress, and work resumes where it stopped.
/// * Only a small LRU of pages is kept in memory.
@MainActor
final class OCRStore {
    let docID: UUID
    let pageCount: Int

    private(set) var meta: [Int: PageMeta] = [:]
    var onPageReady: ((Int) -> Void)?

    private var cache: [Int: OCRPage] = [:]
    private var cacheOrder: [Int] = []
    private let cacheLimit = 40
    private var focus = 0
    private var waiters: [Int: [CheckedContinuation<OCRPage?, Never>]] = [:]
    private var worker: Task<Void, Never>?

    var doneCount: Int { meta.count }
    var isComplete: Bool { meta.count >= pageCount }

    init(docID: UUID, pageCount: Int) {
        self.docID = docID
        self.pageCount = pageCount
        try? FileManager.default.createDirectory(at: Storage.ocrFolder(docID), withIntermediateDirectories: true)
        meta = Storage.load([Int: PageMeta].self, from: Storage.ocrIndexURL(docID)) ?? [:]
        recoverUnindexedPages()
    }

    // MARK: Reading

    func page(_ index: Int) -> OCRPage? {
        if let p = cache[index] { touch(index); return p }
        guard meta[index] != nil else { return nil }
        guard let p = Storage.load(OCRPage.self, from: Storage.ocrPageURL(docID, index)) else {
            // Missing / corrupt file: forget it so it gets recognised again.
            meta[index] = nil
            start()
            return nil
        }
        insert(index, p)
        return p
    }

    /// Returns the page, recognising it first (with top priority) if needed.
    func ensure(_ index: Int) async -> OCRPage? {
        guard index >= 0, index < pageCount else { return nil }
        if let p = page(index) { return p }
        focus = index
        let result: OCRPage? = await withCheckedContinuation { cont in
            waiters[index, default: []].append(cont)
            start()
        }
        return result
    }

    /// Recognition proceeds forward from this page.
    func setFocus(_ index: Int) {
        focus = max(0, min(index, pageCount - 1))
    }

    // MARK: Worker

    func start() {
        guard worker == nil, !isComplete || !waiters.isEmpty else { return }
        let id = docID
        let url = Storage.pdfURL(id)
        worker = Task.detached(priority: .utility) { [weak self] in
            guard let pdf = CGPDFDocument(url as CFURL) else {
                await self?.workerEnded()
                return
            }
            while !Task.isCancelled {
                guard let next = await self?.claimNext() else { break }
                let result: OCRPage = autoreleasepool { OCREngine.recognize(pdf: pdf, index: next) }
                let pageMeta = PageLayout.meta(for: result)
                Storage.save(result, to: Storage.ocrPageURL(id, next))
                await self?.finish(next, page: result, meta: pageMeta)
            }
            await self?.workerEnded()
        }
    }

    func stop() {
        worker?.cancel()
        worker = nil
    }

    private func claimNext() -> Int? {
        if let urgent = waiters.keys.sorted().first(where: { meta[$0] == nil }) { return urgent }
        guard pageCount > 0 else { return nil }
        for offset in 0..<pageCount {
            let i = (focus + offset) % pageCount
            if meta[i] == nil { return i }
        }
        return nil
    }

    private func finish(_ index: Int, page: OCRPage, meta pageMeta: PageMeta) {
        meta[index] = pageMeta
        insert(index, page)
        Storage.save(meta, to: Storage.ocrIndexURL(docID))
        if let conts = waiters.removeValue(forKey: index) {
            conts.forEach { $0.resume(returning: page) }
        }
        onPageReady?(index)
    }

    private func workerEnded() {
        worker = nil
        // Anyone still waiting (e.g. the PDF failed to open) gets nil rather than hanging.
        let pending = waiters
        waiters.removeAll()
        for (index, conts) in pending {
            let p = page(index)
            conts.forEach { $0.resume(returning: p) }
        }
    }

    // MARK: Helpers

    private func recoverUnindexedPages() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Storage.ocrFolder(docID).path)) ?? []
        var changed = false
        for name in files where name.hasPrefix("p") && name.hasSuffix(".json") {
            guard let n = Int(name.dropFirst().dropLast(5)), n < pageCount, meta[n] == nil,
                  let page = Storage.load(OCRPage.self, from: Storage.ocrPageURL(docID, n)) else { continue }
            meta[n] = PageLayout.meta(for: page)
            changed = true
        }
        if changed { Storage.save(meta, to: Storage.ocrIndexURL(docID)) }
    }

    private func insert(_ index: Int, _ page: OCRPage) {
        cache[index] = page
        touch(index)
        while cacheOrder.count > cacheLimit {
            let old = cacheOrder.removeFirst()
            cache[old] = nil
        }
    }

    private func touch(_ index: Int) {
        if let i = cacheOrder.firstIndex(of: index) { cacheOrder.remove(at: i) }
        cacheOrder.append(index)
    }
}
