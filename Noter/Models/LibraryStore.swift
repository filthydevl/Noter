import Foundation
import PDFKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var documents: [DocumentInfo] = []
    /// Your folders, in the order you made them.
    @Published private(set) var folders: [LibraryFolder] = []
    @Published private(set) var importing = false
    @Published var lastError: String?

    init() {
        folders = Storage.load([LibraryFolder].self, from: Self.foldersURL) ?? []
        reload()
    }

    // MARK: Folders

    private static var foldersURL: URL {
        Storage.libraryRoot.deletingLastPathComponent().appendingPathComponent("folders.json")
    }

    private func saveFolders() {
        Storage.save(folders, to: Self.foldersURL)
    }

    /// A new folder, at the top level or inside `parent`.
    @discardableResult
    func createFolder(named name: String, in parent: LibraryFolder? = nil) -> LibraryFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = LibraryFolder(id: UUID(), name: trimmed.isEmpty ? "New folder" : trimmed, parentID: parent?.id)
        folders.append(folder)
        saveFolders()
        return folder
    }

    func rename(_ folder: LibraryFolder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[i].name = trimmed
        saveFolders()
    }

    /// Deletes the folder; its books and folders move up into the folder it was in
    /// (or the top level). Nothing else is deleted.
    func delete(_ folder: LibraryFolder) {
        for doc in documents where doc.folderID == folder.id { setFolder(folder.parentID, for: doc, reloading: false) }
        for i in folders.indices where folders[i].parentID == folder.id { folders[i].parentID = folder.parentID }
        folders.removeAll { $0.id == folder.id }
        saveFolders()
        reload()
    }

    // MARK: Folders in folders

    /// The folders directly inside `parent` (nil: the top level), A–Z.
    func subfolders(of parent: UUID?) -> [LibraryFolder] {
        folders.filter { $0.parentID == parent }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A folder and every folder inside it, however deep.
    func folderAndDescendants(_ id: UUID) -> Set<UUID> {
        var out: Set<UUID> = [id]
        var frontier = [id]
        while let next = frontier.popLast() {
            for f in folders where f.parentID == next && !out.contains(f.id) {
                out.insert(f.id)
                frontier.append(f.id)
            }
        }
        return out
    }

    /// From the top level down to the folder.
    func path(to id: UUID) -> [LibraryFolder] {
        var out: [LibraryFolder] = []
        var current = folders.first { $0.id == id }
        var seen = Set<UUID>()
        while let f = current, seen.insert(f.id).inserted {
            out.insert(f, at: 0)
            current = f.parentID.flatMap { p in folders.first { $0.id == p } }
        }
        return out
    }

    /// "Group › Folder"
    func pathName(of id: UUID) -> String {
        path(to: id).map(\.name).joined(separator: " › ")
    }

    /// Whether `folder` can go into `parent` (not into itself or a folder inside it).
    func canMove(_ folder: LibraryFolder, into parent: LibraryFolder?) -> Bool {
        guard let parent else { return folder.parentID != nil }
        return !folderAndDescendants(folder.id).contains(parent.id) && folder.parentID != parent.id
    }

    /// Groups a folder inside another (nil: back to the top level).
    func move(folder: LibraryFolder, into parent: LibraryFolder?) {
        guard canMove(folder, into: parent), let i = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[i].parentID = parent?.id
        saveFolders()
    }

    func move(folderID: UUID, into parent: LibraryFolder?) {
        guard let f = folders.first(where: { $0.id == folderID }) else { return }
        move(folder: f, into: parent)
    }

    func move(_ doc: DocumentInfo, to folder: LibraryFolder?) {
        setFolder(folder?.id, for: doc, reloading: true)
    }

    func move(docID: UUID, to folder: LibraryFolder?) {
        guard let doc = documents.first(where: { $0.id == docID }) else { return }
        move(doc, to: folder)
    }

    private func setFolder(_ id: UUID?, for doc: DocumentInfo, reloading: Bool) {
        // Re-read the info from disk so nothing saved by the reader is lost.
        guard var info = Storage.load(DocumentInfo.self, from: Storage.infoURL(doc.id)) else { return }
        info.folderID = id
        Storage.save(info, to: Storage.infoURL(doc.id))
        if reloading { reload() }
    }

    /// Books in the folder, including the folders inside it.
    func count(in folder: LibraryFolder) -> Int {
        let ids = folderAndDescendants(folder.id)
        return documents.filter { $0.folderID.map(ids.contains) ?? false }.count
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Storage.libraryRoot, includingPropertiesForKeys: nil)) ?? []
        var docs: [DocumentInfo] = []
        for url in urls {
            guard let id = UUID(uuidString: url.lastPathComponent),
                  let info = Storage.load(DocumentInfo.self, from: Storage.infoURL(id)) else { continue }
            docs.append(info)
        }
        documents = docs.sorted { ($0.lastOpened ?? $0.added) > ($1.lastOpened ?? $1.added) }
        // Unfinished books keep being read in the background.
        BackgroundOCR.shared.libraryChanged(documents)
    }

    /// Copies the PDFs into the library. Returns the ids of the new documents.
    @discardableResult
    func importPDFs(_ urls: [URL], into folder: LibraryFolder? = nil) async -> [UUID] {
        importing = true
        defer { importing = false }
        var ids: [UUID] = []
        for url in urls {
            do {
                var info = try await Self.importOne(url)
                if let folder {
                    info.folderID = folder.id
                    Storage.save(info, to: Storage.infoURL(info.id))
                }
                ids.append(info.id)
            } catch {
                lastError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        reload()
        return ids
    }

    func delete(_ doc: DocumentInfo) {
        try? FileManager.default.removeItem(at: Storage.folder(doc.id))
        for url in Storage.exportURLs(for: doc) { try? FileManager.default.removeItem(at: url) }
        reload()
    }

    /// Runs off the main thread: copying a several-hundred-MB scan must not freeze the UI.
    nonisolated private static func importOne(_ url: URL) async throws -> DocumentInfo {
        try await Task.detached(priority: .userInitiated) { () throws -> DocumentInfo in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let id = UUID()
            let folder = Storage.folder(id)
            let fm = FileManager.default
            try fm.createDirectory(at: Storage.ocrFolder(id), withIntermediateDirectories: true)
            let dest = Storage.pdfURL(id)

            do {
                // Coordinated read so iCloud Drive files are downloaded first.
                var coordError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                    do { try fm.copyItem(at: readURL, to: dest) } catch { copyError = error }
                }
                if let e = coordError { throw e }
                if let e = copyError { throw e }

                guard let doc = PDFDocument(url: dest), doc.pageCount > 0 else { throw NoterError.unreadablePDF }
                if doc.isLocked { throw NoterError.lockedPDF }

                let info = DocumentInfo(
                    id: id,
                    title: url.deletingPathExtension().lastPathComponent,
                    pageCount: doc.pageCount,
                    added: Date(),
                    lastOpened: nil,
                    layoutMode: .auto,
                    lastPage: 0,
                    viewMode: .pdf,
                    highlightCount: 0,
                    ocrPagesDone: 0)
                Storage.save(info, to: Storage.infoURL(id))
                return info
            } catch {
                try? fm.removeItem(at: folder)
                throw error
            }
        }.value
    }
}
