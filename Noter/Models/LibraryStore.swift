import Foundation
import PDFKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var documents: [DocumentInfo] = []
    @Published private(set) var importing = false
    @Published var lastError: String?

    init() {
        reload()
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
    func importPDFs(_ urls: [URL]) async -> [UUID] {
        importing = true
        defer { importing = false }
        var ids: [UUID] = []
        for url in urls {
            do {
                let info = try await Self.importOne(url)
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
        try? FileManager.default.removeItem(at: Storage.exportURL(for: doc))
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
