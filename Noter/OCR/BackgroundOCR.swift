import Foundation

/// Keeps reading the text of your PDFs after you leave them, so a 1000-page book isn't
/// stuck where you left off. One book at a time, and only while no book is open (the
/// open one gets the whole iPad). In the background only the first reading of each page
/// is done; refining waits until you open the book. Every finished page is saved as it
/// goes (see `OCRStore`), so nothing is lost if the app is closed. Its progress shows on
/// the library's covers.
@MainActor
final class BackgroundOCR: ObservableObject {
    static let shared = BackgroundOCR()

    /// Pages with text, per document, as they finish.
    @Published private(set) var progress: [UUID: Int] = [:]
    /// The book being read in the background right now.
    @Published private(set) var working: UUID?

    private var stores: [UUID: OCRStore] = [:]
    private var openInReader = Set<UUID>()
    private var library: [DocumentInfo] = []
    /// Books whose PDF couldn't be read: not retried until the app restarts.
    private var failed = Set<UUID>()
    private var lastSaved: [UUID: Int] = [:]
    /// Held back for a few seconds after the app starts, so the library opens at once
    /// (loading a big book's progress and reading pages competed with it).
    private var launchHold = true
    private var holdScheduled = false

    private init() {}

    // MARK: Reader

    /// The store for a book you're opening: the background one if it's been working on
    /// this book (it keeps its place), else a new one. Background work pauses.
    func attach(_ id: UUID, pageCount: Int) -> OCRStore {
        openInReader.insert(id)
        let store = stores[id] ?? OCRStore(docID: id, pageCount: pageCount)
        stores[id] = store
        store.firstPassOnly = false
        store.onWorkerEnded = nil
        schedule()
        return store
    }

    /// You left the book: it carries on in the background.
    func detach(_ id: UUID) {
        openInReader.remove(id)
        guard let store = stores[id] else { return }
        store.onPageReady = nil
        store.stop()
        progress[id] = store.doneCount
        if let i = library.firstIndex(where: { $0.id == id }) { library[i].ocrPagesDone = store.doneCount }
        if store.isComplete { stores[id] = nil } // nothing left to read: free its memory
        schedule()
    }

    /// The library changed (a book added or deleted, or the app started).
    func libraryChanged(_ docs: [DocumentInfo]) {
        library = docs
        let ids = Set(docs.map(\.id))
        for (id, store) in stores where !ids.contains(id) {
            store.stop()
            stores[id] = nil
            progress[id] = nil
        }
        for doc in docs where progress[doc.id] == nil { progress[doc.id] = doc.ocrPagesDone }
        if launchHold {
            guard !holdScheduled else { return }
            holdScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.launchHold = false
                self?.schedule()
            }
            return
        }
        schedule()
    }

    // MARK: Scheduling

    private func schedule() {
        if launchHold && openInReader.isEmpty { return } // the app is still starting
        // A book is open: it has the iPad to itself.
        if !openInReader.isEmpty {
            for (id, store) in stores where !openInReader.contains(id) { store.stop() }
            working = nil
            return
        }
        // Next unfinished book: the one you opened most recently first.
        let next = library.first { doc in
            !failed.contains(doc.id) && (progress[doc.id] ?? doc.ocrPagesDone) < doc.pageCount && doc.pageCount > 0
        }
        for (id, store) in stores where id != next?.id { store.stop() }
        guard let doc = next else {
            working = nil
            return
        }
        let store = stores[doc.id] ?? OCRStore(docID: doc.id, pageCount: doc.pageCount)
        stores[doc.id] = store
        progress[doc.id] = store.doneCount
        guard !store.isComplete else {
            finished(doc.id)
            return
        }
        working = doc.id
        store.firstPassOnly = true
        store.onPageReady = { [weak self, weak store] _ in
            guard let self, let store else { return }
            self.pageDone(doc.id, store)
        }
        store.onWorkerEnded = { [weak self, weak store] in
            guard let self, let store, self.working == doc.id else { return }
            if store.isComplete {
                self.finished(doc.id)
            } else if self.openInReader.isEmpty {
                self.failed.insert(doc.id) // the PDF couldn't be read: don't spin on it
                self.working = nil
                self.schedule()
            }
        }
        store.start()
    }

    private func pageDone(_ id: UUID, _ store: OCRStore) {
        let done = store.doneCount
        progress[id] = done
        // The library card reads this from the book's info file too (after a restart).
        if done - (lastSaved[id] ?? 0) >= 10 || store.isComplete { saveProgress(id, done) }
        if store.isComplete { finished(id) }
    }

    private func finished(_ id: UUID) {
        if let store = stores[id] {
            saveProgress(id, store.doneCount)
            store.onPageReady = nil
            store.onWorkerEnded = nil
            if !openInReader.contains(id) { stores[id] = nil } // free its memory
        }
        if working == id { working = nil }
        if let i = library.firstIndex(where: { $0.id == id }) { library[i].ocrPagesDone = library[i].pageCount }
        schedule()
    }

    private func saveProgress(_ id: UUID, _ done: Int) {
        lastSaved[id] = done
        guard var info = Storage.load(DocumentInfo.self, from: Storage.infoURL(id)) else { return }
        info.ocrPagesDone = done
        Storage.save(info, to: Storage.infoURL(id))
    }
}
