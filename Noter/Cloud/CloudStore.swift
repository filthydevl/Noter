import Foundation

/// Books kept in a folder you pick in the Files app — iCloud Drive, typically. Only
/// the PDFs go there (they're nearly all of Noter's size); highlights, notes and the
/// recognized text stay on the iPad (they're small and used all the time). iPadOS
/// keeps the books you read on the iPad and frees the others when it needs room,
/// downloading them again when you open them.
final class CloudStore: @unchecked Sendable {
    static let shared = CloudStore()

    private let lock = NSLock()
    private var folder: URL?
    /// Book → file name inside the folder.
    private var names: [UUID: String] = [:]

    private static let bookmarkKey = "noter.cloudFolderBookmark"
    private static var indexURL: URL {
        Storage.libraryRoot.deletingLastPathComponent().appendingPathComponent("cloud-books.json")
    }

    private init() {
        names = Storage.load([UUID: String].self, from: Self.indexURL) ?? [:]
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) {
                // Held open for as long as the app runs.
                _ = url.startAccessingSecurityScopedResource()
                folder = url
                if stale, let fresh = try? url.bookmarkData() {
                    UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
                }
            }
        }
    }

    var folderURL: URL? { lock.withLock { folder } }
    var folderName: String? { folderURL?.lastPathComponent }
    var isOn: Bool { folderURL != nil }

    /// The book's PDF in the folder, if it lives there.
    func url(for id: UUID) -> URL? {
        lock.withLock {
            guard let folder, let name = names[id] else { return nil }
            return folder.appendingPathComponent(name)
        }
    }

    /// The PDF is in the folder but iPadOS has freed it from the iPad for now.
    func needsDownload(_ id: UUID) -> Bool {
        guard let url = url(for: id) else { return false }
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = values?.ubiquitousItemDownloadingStatus else {
            return !FileManager.default.fileExists(atPath: url.path)
        }
        return status == .notDownloaded
    }

    /// Fetches a freed book back onto the iPad. Returns when it's there (or failed).
    func download(_ id: UUID, timeout: TimeInterval = 120) async -> Bool {
        guard let url = url(for: id) else { return true }
        guard needsDownload(id) else { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !needsDownload(id) { return true }
        }
        return false
    }

    // MARK: Setting up

    /// Uses this folder from now on and moves every book's PDF into it.
    func use(folder picked: URL, documents: [DocumentInfo]) throws {
        guard picked.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileReadNoPermission)
        }
        let bookmark = try picked.bookmarkData()
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        lock.withLock { folder = picked }
        for doc in documents { try? moveIn(doc) }
    }

    /// Moves one book's PDF from the iPad into the folder (a new import, or the first
    /// time the folder is set up).
    func moveIn(_ doc: DocumentInfo) throws {
        guard let folder = folderURL, url(for: doc.id) == nil else { return }
        let local = Storage.localPDFURL(doc.id)
        guard FileManager.default.fileExists(atPath: local.path) else { return }
        let name = Self.fileName(for: doc, in: folder)
        let dest = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: local, to: dest)
        // Only once the copy is really there does the iPad's copy go.
        guard let size = try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            try? FileManager.default.removeItem(at: dest)
            return
        }
        lock.withLock {
            names[doc.id] = name
            Storage.save(names, to: Self.indexURL)
        }
        try? FileManager.default.removeItem(at: local)
    }

    /// Brings every book back onto the iPad and stops using the folder (the files in
    /// it are left where they are).
    func stop() async {
        let ids = lock.withLock { Array(names.keys) }
        for id in ids {
            guard await download(id), let url = url(for: id) else { continue }
            let local = Storage.localPDFURL(id)
            if (try? FileManager.default.copyItem(at: url, to: local)) != nil
                || FileManager.default.fileExists(atPath: local.path) {
                lock.withLock { names[id] = nil }
            }
        }
        lock.withLock {
            Storage.save(names, to: Self.indexURL)
            if names.isEmpty {
                folder?.stopAccessingSecurityScopedResource()
                folder = nil
                UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            }
        }
    }

    /// You removed the reading: its file in the folder goes too.
    func remove(_ id: UUID) {
        guard let url = url(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
        lock.withLock {
            names[id] = nil
            Storage.save(names, to: Self.indexURL)
        }
    }

    /// "Italy Revolution and Counterrevolution.pdf" (a number added if taken).
    private static func fileName(for doc: DocumentInfo, in folder: URL) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var base = LibraryTitles.clean(doc.title).components(separatedBy: bad).joined(separator: "-")
        if base.isEmpty { base = doc.id.uuidString }
        base = String(base.prefix(100))
        var name = base + ".pdf"
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base) \(n).pdf"
            n += 1
        }
        return name
    }
}

/// Book titles as people read them: the details found for citations if there are
/// any, else the file name tidied up ("17+italy_revolution_and_counterrevolution_
/// 17891799" → "Italy Revolution and Counterrevolution 1789–1799").
enum LibraryTitles {
    static func clean(_ raw: String) -> String {
        SourceInfo.looksLikeFileName(raw) ? SourceInfo.cleanedFileTitle(raw) : raw
    }

    static func title(of doc: DocumentInfo) -> String {
        if let s = Storage.load(SourceInfo.self, from: SourceInfo.url(doc.id)),
           !s.title.trimmingCharacters(in: .whitespaces).isEmpty, !SourceInfo.looksLikeFileName(s.title) {
            return s.title
        }
        return clean(doc.title)
    }
}

/// How much room each part of Noter takes on the iPad.
enum StorageReport {
    struct Usage {
        var books: Int64 = 0
        var text: Int64 = 0
        var audio: Int64 = 0
        var other: Int64 = 0
        var total: Int64 { books + text + audio + other }
    }

    static func size(of url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in walker {
            let v = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    static func measure() -> Usage {
        var u = Usage()
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: Storage.libraryRoot, includingPropertiesForKeys: nil)) ?? [] {
            let pdf = folder.appendingPathComponent("document.pdf")
            let pdfSize = (try? pdf.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize).map(Int64.init) ?? 0
            u.books += pdfSize
            u.text += size(of: folder.appendingPathComponent("ocr"))
            u.other += max(size(of: folder) - pdfSize - size(of: folder.appendingPathComponent("ocr")), 0)
        }
        u.audio = size(of: speechifyCache)
        u.other += size(of: Storage.exportFolder)
        return u
    }

    static var speechifyCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Speechify")
    }

    static func clearAudio() {
        try? FileManager.default.removeItem(at: speechifyCache)
        try? FileManager.default.createDirectory(at: speechifyCache, withIntermediateDirectories: true)
    }
}
