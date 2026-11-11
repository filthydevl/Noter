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
        /// A new folder (inside `parent`), and the book to move into it.
        case new(moving: UUID?, parent: UUID?)
        case rename(LibraryFolder)

        var id: String {
            switch self {
            case .new(let id, let parent): "new-\(id?.uuidString ?? "")-\(parent?.uuidString ?? "")"
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
                        if let current = currentFolder, library.path(to: current.id).count > 1 {
                            breadcrumbs(current)
                        }
                        if shown.isEmpty && innerFolders.isEmpty {
                            ContentUnavailableView(
                                "Nothing in this folder yet",
                                systemImage: "folder",
                                description: Text("Long-press a book › Move to Folder, or drag a book onto a folder above."))
                                .frame(maxHeight: .infinity)
                        } else {
                            ScrollView {
                                LazyVGrid(columns: columns, spacing: 36) {
                                    // Folders grouped in this one first, then its books.
                                    ForEach(innerFolders) { f in
                                        Button {
                                            shelf = .folder(f.id)
                                        } label: {
                                            FolderCard(folder: f, books: library.count(in: f),
                                                       folders: library.subfolders(of: f.id).count)
                                        }
                                        .buttonStyle(.plain)
                                        .draggable("folder:\(f.id.uuidString)")
                                        .dropDestination(for: String.self) { items, _ in drop(items, into: f) }
                                        .contextMenu { folderMenu(f) }
                                    }
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
                        naming = .new(moving: nil, parent: currentFolder?.id)
                    } label: {
                        Label(currentFolder == nil ? "New folder" : "New folder in “\(currentFolder!.name)”",
                              systemImage: "folder.badge.plus")
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
                "Delete the folder “\(pendingFolderDelete?.name ?? "")”? Its books and folders move up a level.",
                isPresented: Binding(get: { pendingFolderDelete != nil }, set: { if !$0 { pendingFolderDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete folder", role: .destructive) {
                    if let f = pendingFolderDelete {
                        // Inside it (or a folder in it)? Go up to where it was.
                        if case .folder(let id) = shelf, library.folderAndDescendants(f.id).contains(id) {
                            shelf = f.parentID.map { .folder($0) } ?? .all
                        }
                        library.delete(f)
                    }
                    pendingFolderDelete = nil
                }
            }
            .onAppear { library.reload() }
        }
    }

    /// The book's folder ("Group › Folder"), shown on its card in "All".
    private func folderName(of doc: DocumentInfo) -> String? {
        guard shelf == .all, let id = doc.folderID, library.folders.contains(where: { $0.id == id }) else { return nil }
        return library.pathName(of: id)
    }

    /// The folders grouped inside the folder you're in.
    private var innerFolders: [LibraryFolder] {
        guard let current = currentFolder else { return [] }
        return library.subfolders(of: current.id)
    }

    /// The top-level folder you're somewhere inside (its chip is the selected one).
    private var currentRoot: UUID? {
        guard let current = currentFolder else { return nil }
        return library.path(to: current.id).first?.id
    }

    /// Books (their ids) and folders ("folder:<id>") dropped on a folder (nil: out of
    /// any folder / the top level).
    private func drop(_ items: [String], into folder: LibraryFolder?) -> Bool {
        var moved = false
        for item in items {
            if item.hasPrefix("folder:"), let id = UUID(uuidString: String(item.dropFirst(7))) {
                if let f = library.folders.first(where: { $0.id == id }), library.canMove(f, into: folder) {
                    library.move(folder: f, into: folder)
                    moved = true
                }
            } else if let id = UUID(uuidString: item) {
                library.move(docID: id, to: folder)
                moved = true
            }
        }
        return moved
    }

    /// Library › Group › Folder — tap one to go back up.
    private func breadcrumbs(_ current: LibraryFolder) -> some View {
        let path = library.path(to: current.id)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(path.enumerated()), id: \.element.id) { i, f in
                    if i > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        shelf = .folder(f.id)
                    } label: {
                        Text(f.name)
                            .font(.subheadline.weight(i == path.count - 1 ? .semibold : .regular))
                            .foregroundStyle(i == path.count - 1 ? Color.primary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(i == path.count - 1)
                    .dropDestination(for: String.self) { items, _ in drop(items, into: f) }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 4)
        }
    }

    /// Rename, new folder inside, move into another folder, delete.
    @ViewBuilder
    private func folderMenu(_ f: LibraryFolder) -> some View {
        Button {
            nameDraft = f.name
            naming = .rename(f)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            nameDraft = ""
            naming = .new(moving: nil, parent: f.id)
        } label: {
            Label("New folder inside", systemImage: "folder.badge.plus")
        }
        Menu {
            if f.parentID != nil {
                Button {
                    library.move(folder: f, into: nil)
                } label: {
                    Label("Top level", systemImage: "arrow.up.to.line")
                }
            }
            ForEach(library.folders.filter { library.canMove(f, into: $0) }
                .sorted { library.pathName(of: $0.id).localizedCaseInsensitiveCompare(library.pathName(of: $1.id)) == .orderedAscending }) { target in
                Button(library.pathName(of: target.id)) { library.move(folder: f, into: target) }
            }
        } label: {
            Label("Move into…", systemImage: "folder")
        }
        Button(role: .destructive) {
            pendingFolderDelete = f
        } label: {
            Label("Delete folder", systemImage: "trash")
        }
    }

    // MARK: Folder bar

    /// All · your folders · Not in a folder · New folder. Drop a book on a folder to move it.
    private var folderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", systemImage: "books.vertical", count: library.documents.count, selected: shelf == .all) {
                    shelf = .all
                }
                ForEach(library.subfolders(of: nil)) { f in
                    let groups = !library.subfolders(of: f.id).isEmpty
                    chip(f.name, systemImage: groups ? "folder.badge.gearshape" : "folder", count: library.count(in: f),
                         selected: currentRoot == f.id) {
                        shelf = .folder(f.id)
                    }
                    .draggable("folder:\(f.id.uuidString)")
                    .dropDestination(for: String.self) { items, _ in drop(items, into: f) }
                    .contextMenu { folderMenu(f) }
                }
                if !library.folders.isEmpty {
                    chip("Not in a folder", systemImage: "tray", count: library.documents.filter { $0.folderID == nil }.count,
                         selected: shelf == .unfiled) {
                        shelf = .unfiled
                    }
                    .dropDestination(for: String.self) { items, _ in drop(items, into: nil) }
                }
                Button {
                    nameDraft = ""
                    naming = .new(moving: nil, parent: currentFolder?.id)
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
            ForEach(library.folders.sorted {
                library.pathName(of: $0.id).localizedCaseInsensitiveCompare(library.pathName(of: $1.id)) == .orderedAscending
            }) { f in
                let name = library.pathName(of: f.id)
                Button {
                    library.move(doc, to: f)
                } label: {
                    if doc.folderID == f.id { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Divider()
            Button {
                nameDraft = ""
                naming = .new(moving: doc.id, parent: currentFolder?.id)
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
        case .new(let moving, let parent):
            let folder = library.createFolder(named: nameDraft,
                                              in: parent.flatMap { p in library.folders.first { $0.id == p } })
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

/// A folder grouped inside the one you're in.
private struct FolderCard: View {
    let folder: LibraryFolder
    let books: Int
    let folders: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    Image(systemName: folders > 0 ? "folder.fill.badge.gearshape" : "folder.fill")
                        .font(.system(size: 54, weight: .regular))
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.25)))
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(folder.name), \(summary)")
    }

    private var summary: String {
        var parts = ["\(books) book\(books == 1 ? "" : "s")"]
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
