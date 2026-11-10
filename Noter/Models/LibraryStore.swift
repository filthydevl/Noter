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

    @discardableResult
    func createFolder(named name: String) -> LibraryFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = LibraryFolder(id: UUID(), name: trimmed.isEmpty ? "New folder" : trimmed)
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

    /// Deletes the folder; its books stay in the library, out of any folder.
    func delete(_ folder: LibraryFolder) {
        for doc in documents where doc.folderID == folder.id { setFolder(nil, for: doc, reloading: false) }
        folders.removeAll { $0.id == folder.id }
        saveFolders()
        reload()
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

    func count(in folder: LibraryFolder) -> Int {
        documents.filter { $0.folderID == folder.id }.count
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
