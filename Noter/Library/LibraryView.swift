import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers

/// Which books the library shows.
enum Shelf: Hashable {
    case all
    case unfiled
    case folder(UUID)
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var reading = BackgroundOCR.shared
    @State private var showImporter = false
    @State private var path: [UUID] = []
    @State private var pendingDelete: DocumentInfo?
    @State private var shelf: Shelf = .all
    /// Naming a folder: a new one (and the book to move into it), or renaming one.
    @State private var naming: Naming?
    @State private var nameDraft = ""
    @State private var pendingFolderDelete: LibraryFolder?

    enum Naming: Identifiable {
        case new(moving: UUID?)
        case rename(LibraryFolder)

        var id: String {
            switch self {
            case .new(let id): "new-\(id?.uuidString ?? "")"
            case .rename(let f): "rename-\(f.id)"
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 28, alignment: .top)]

    private var currentFolder: LibraryFolder? {
        if case .folder(let id) = shelf { return library.folders.first { $0.id == id } }
        return nil
    }

    private var shown: [DocumentInfo] {
        switch shelf {
        case .all: library.documents
        case .unfiled: library.documents.filter { $0.folderID == nil }
        case .folder(let id): library.documents.filter { $0.folderID == id }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.documents.isEmpty {
                    ContentUnavailableView {
                        Label("No books yet", systemImage: "books.vertical")
                    } description: {
                        Text("Import a PDF. Noter reads the text, then you can highlight with your Apple Pencil and listen to it.")
                    } actions: {
                        Button("Import PDF") { showImporter = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                } else {
                    VStack(spacing: 0) {
                        folderBar
                        if shown.isEmpty {
                            ContentUnavailableView(
                                "Nothing in this folder yet",
                                systemImage: "folder",
                                description: Text("Long-press a book › Move to Folder, or drag a book onto a folder above."))
                                .frame(maxHeight: .infinity)
                        } else {
                            ScrollView {
                                LazyVGrid(columns: columns, spacing: 36) {
                                    ForEach(shown) { doc in
                                        NavigationLink(value: doc.id) {
                                            BookCard(doc: doc, folder: folderName(of: doc),
                                                     pagesRead: max(reading.progress[doc.id] ?? 0, doc.ocrPagesDone),
                                                     reading: reading.working == doc.id)
                                        }
                                        .buttonStyle(.plain)
                                        .draggable(doc.id.uuidString)
                                        .contextMenu { bookMenu(doc) }
                                    }
                                }
                                .padding(.horizontal, 32)
                                .padding(.top, 12)
                                .padding(.bottom, 40)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(currentFolder?.name ?? (shelf == .unfiled ? "Not in a folder" : "Library"))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        nameDraft = ""
                        naming = .new(moving: nil)
                    } label: {
                        Label("New folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import PDF", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ReaderScreen(docID: id)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                let folder = currentFolder
                Task { @MainActor in
                    let ids = await library.importPDFs(urls, into: folder)
                    if ids.count == 1 { path = ids }
                }
            }
            .overlay {
                if library.importing {
                    ProgressView("Importing…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .alert("Import failed", isPresented: Binding(
                get: { library.lastError != nil },
                set: { if !$0 { library.lastError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.lastError ?? "")
            }
            .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("Folder name", text: $nameDraft)
                Button("Cancel", role: .cancel) { naming = nil }
                Button(namingIsRename ? "Rename" : "Create") { finishNaming() }
            }
            .confirmationDialog(
                "Delete “\(pendingDelete?.title ?? "")” and its highlights?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let doc = pendingDelete { library.delete(doc) }
                    pendingDelete = nil
                }
            }
            .confirmationDialog(
                "Delete the folder “\(pendingFolderDelete?.name ?? "")”? Its books stay in your library.",
                isPresented: Binding(get: { pendingFolderDelete != nil }, set: { if !$0 { pendingFolderDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete folder", role: .destructive) {
                    if let f = pendingFolderDelete {
                        if shelf == .folder(f.id) { shelf = .all }
                        library.delete(f)
                    }
                    pendingFolderDelete = nil
                }
            }
            .onAppear { library.reload() }
        }
    }

    /// The book's folder, shown on its card in "All".
    private func folderName(of doc: DocumentInfo) -> String? {
        guard shelf == .all, let id = doc.folderID else { return nil }
        return library.folders.first(where: { $0.id == id })?.name
    }

    // MARK: Folder bar

    /// All · your folders · Not in a folder · New folder. Drop a book on a folder to move it.
    private var folderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", systemImage: "books.vertical", count: library.documents.count, selected: shelf == .all) {
                    shelf = .all
                }
                ForEach(library.folders) { f in
                    chip(f.name, systemImage: "folder", count: library.count(in: f), selected: shelf == .folder(f.id)) {
                        shelf = .folder(f.id)
                    }
                    .dropDestination(for: String.self) { items, _ in
                        for item in items { if let id = UUID(uuidString: item) { library.move(docID: id, to: f) } }
                        return !items.isEmpty
                    }
                    .contextMenu {
                        Button {
                            nameDraft = f.name
                            naming = .rename(f)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            pendingFolderDelete = f
                        } label: {
                            Label("Delete folder", systemImage: "trash")
                        }
                    }
                }
                if !library.folders.isEmpty {
                    chip("Not in a folder", systemImage: "tray", count: library.documents.filter { $0.folderID == nil }.count,
                         selected: shelf == .unfiled) {
                        shelf = .unfiled
                    }
                    .dropDestination(for: String.self) { items, _ in
                        for item in items { if let id = UUID(uuidString: item) { library.move(docID: id, to: nil) } }
                        return !items.isEmpty
                    }
                }
                Button {
                    nameDraft = ""
                    naming = .new(moving: nil)
                } label: {
                    Label("New folder", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 10)
        }
    }

    private func chip(_ title: String, systemImage: String, count: Int, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected && systemImage == "folder" ? "folder.fill" : systemImage)
                Text(title).lineLimit(1)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(selected ? Color.accentColor : Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Book menu

    @ViewBuilder
    private func bookMenu(_ doc: DocumentInfo) -> some View {
        Menu {
            Button {
                library.move(doc, to: nil)
            } label: {
                if doc.folderID == nil { Label("Not in a folder", systemImage: "checkmark") } else { Text("Not in a folder") }
            }
            ForEach(library.folders) { f in
                Button {
                    library.move(doc, to: f)
                } label: {
                    if doc.folderID == f.id { Label(f.name, systemImage: "checkmark") } else { Text(f.name) }
                }
            }
            Divider()
            Button {
                nameDraft = ""
                naming = .new(moving: doc.id)
            } label: {
                Label("New folder…", systemImage: "folder.badge.plus")
            }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }
        Button(role: .destructive) {
            pendingDelete = doc
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: Naming folders

    private var namingIsRename: Bool {
        if case .rename = naming { return true }
        return false
    }

    private var namingTitle: String { namingIsRename ? "Rename folder" : "New folder" }

    private func finishNaming() {
        switch naming {
        case .new(let moving):
            let folder = library.createFolder(named: nameDraft)
            if let moving { library.move(docID: moving, to: folder) }
        case .rename(let folder):
            library.rename(folder, to: nameDraft)
        case nil:
            break
        }
        naming = nil
    }
}

private struct BookCard: View {
    let doc: DocumentInfo
    /// Shown under the title in "All".
    var folder: String? = nil
    /// Pages whose text has been read so far.
    var pagesRead = 0
    /// Being read in the background right now.
    var reading = false
    @State private var cover: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    if let cover {
                        Image(uiImage: cover)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "doc.text")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
                }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06)))
            .overlay(alignment: .topTrailing) {
                if pagesRead < doc.pageCount {
                    ReadingRing(done: pagesRead, total: doc.pageCount, active: reading)
                        .padding(8)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if pagesRead < doc.pageCount {
                    Text(reading ? "Reading text · \(pagesRead)/\(doc.pageCount)"
                         : "Text read on \(pagesRead)/\(doc.pageCount) pages")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(reading ? Color.accentColor : .secondary)
                        .accessibilityHidden(true) // the ring says it
                }
            }
        }
        .contentShape(Rectangle())
        .task(id: doc.id) {
            cover = await Thumbnailer.thumbnail(for: doc.id)
        }
    }

    private var subtitle: String {
        var parts = ["\(doc.pageCount) pages"]
        if let folder { parts.insert(folder, at: 0) }
        if doc.highlightCount > 0 {
            parts.append("\(doc.highlightCount) highlight\(doc.highlightCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

enum Thumbnailer {
    static func thumbnail(for id: UUID) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            let url = Storage.thumbnailURL(id)
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) { return image }
            guard let doc = PDFDocument(url: Storage.pdfURL(id)), let page = doc.page(at: 0) else { return nil }
            let image = page.thumbnail(of: CGSize(width: 420, height: 560), for: .cropBox)
            if let data = image.jpegData(compressionQuality: 0.82) { try? data.write(to: url, options: .atomic) }
            return image
        }.value
    }
}

/// On a book's cover while its text is still being read: how far along it is.
private struct ReadingRing: View {
    let done: Int
    let total: Int
    /// Being read right now (it turns slowly), or waiting its turn.
    let active: Bool
    @State private var spin = false

    var body: some View {
        let fraction = Double(done) / Double(max(total, 1))
        ZStack {
            Circle().fill(.regularMaterial)
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 4).padding(5)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(active ? Color.accentColor : Color.secondary,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(5)
            Text("\(Int((fraction * 100).rounded(.down)))%")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(width: 46, height: 46)
        .overlay {
            if active {
                // A small dot going round: work is happening.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .offset(y: -23)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            }
        }
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .accessibilityElement()
        .accessibilityLabel(active ? "Reading the text" : "Text not read yet on every page")
        .accessibilityValue("\(done) of \(total) pages")
    }
}
