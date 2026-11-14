import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers

/// Which books the library shows.
enum Shelf: Hashable {
    /// The start page: your folders, then the books that aren't in one.
    case home
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
    @State private var shelf: Shelf = .home
    /// The folder whose name, color and icon you're changing.
    @State private var customizing: LibraryFolder?
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
        case .home, .unfiled: library.documents.filter { $0.folderID == nil }
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
                        if let current = currentFolder { breadcrumbs(current) }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                // Folders first (on the start page), or the groups inside
                                // the folder you're in; then the books.
                                if shelf != .all, shelf != .unfiled {
                                    sectionTitle(currentFolder == nil ? "Folders" : "Groups")
                                    LazyVGrid(columns: folderColumns, spacing: 14) {
                                        ForEach(foldersHere) { f in
                                            FolderTile(folder: f, books: library.count(in: f),
                                                       folders: library.subfolders(of: f.id).count,
                                                       open: { shelf = .folder(f.id) }) { folderMenu(f) }
                                                .draggable("folder:\(f.id.uuidString)")
                                                .dropDestination(for: String.self) { items, _ in drop(items, into: f) }
                                                .contextMenu { folderMenu(f) }
                                        }
                                        NewFolderTile(title: currentFolder == nil ? "New folder" : "New group") {
                                            nameDraft = ""
                                            naming = .new(moving: nil, parent: currentFolder?.id)
                                        }
                                    }
                                }
                                if !shown.isEmpty {
                                    sectionTitle(booksTitle)
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
                                } else if currentFolder != nil {
                                    Text("No books here yet. Drag a book onto this folder, long-press a book › Move to Folder, or import one while you're in here.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                }
                            }
                            .padding(.horizontal, 32)
                            .padding(.top, 8)
                            .padding(.bottom, 40)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(currentFolder?.name ?? (shelf == .all ? "All books" : "Library"))
            .sheet(item: $customizing) { f in
                FolderCustomizeView(folder: f) { name, color, symbol in
                    library.customize(f, name: name, colorHex: color, symbol: symbol)
                }
            }
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
                            shelf = f.parentID.map { .folder($0) } ?? .home
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

    /// The folders shown as tiles: the top-level ones on the start page, the groups
    /// inside the folder you're in.
    private var foldersHere: [LibraryFolder] { library.subfolders(of: currentFolder?.id) }

    private let folderColumns = [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 14, alignment: .top)]

    private var booksTitle: String {
        switch shelf {
        case .home: "Not in a folder"
        case .all: "All books"
        case .unfiled: "Not in a folder"
        case .folder: "Books"
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 6)
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
                // Back to the start page (drop a book or folder here to take it out).
                Button {
                    shelf = .home
                } label: {
                    Label("Library", systemImage: "chevron.left")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .dropDestination(for: String.self) { items, _ in drop(items, into: nil) }
                ForEach(Array(path.enumerated()), id: \.element.id) { i, f in
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
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
            customizing = f
        } label: {
            Label("Name, color & icon…", systemImage: "paintpalette")
        }
        Button {
            nameDraft = ""
            naming = .new(moving: nil, parent: f.id)
        } label: {
            Label("New group inside", systemImage: "folder.badge.plus")
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

    /// Folders (the start page) · All books.
    private var folderBar: some View {
        HStack(spacing: 8) {
            chip("Folders", systemImage: "folder", count: library.folders.count,
                 selected: shelf != .all) {
                shelf = .home
            }
            chip("All books", systemImage: "books.vertical", count: library.documents.count, selected: shelf == .all) {
                shelf = .all
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 10)
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

/// A folder (or a group inside one): its icon in its color, its name, what's in it,
/// and a ⋯ menu.
private struct FolderTile<MenuItems: View>: View {
    let folder: LibraryFolder
    let books: Int
    let folders: Int
    let open: () -> Void
    @ViewBuilder let menu: () -> MenuItems

    private var tint: Color { FolderLook.color(folder.colorHex) }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Image(systemName: folder.symbol ?? "folder.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 46, height: 46)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Folder \(folder.name), \(summary)")
            Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Options for \(folder.name)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }

    private var summary: String {
        var parts = ["\(books) book\(books == 1 ? "" : "s")"]
        if folders > 0 { parts.append("\(folders) group\(folders == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// The dashed "+" tile at the end of the folders.
private struct NewFolderTile: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 46, height: 46)
                Text(title).font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
            .padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The colors and icons a folder can have.
enum FolderLook {
    static let colors: [(name: String, hex: String)] = [
        ("Blue", "#3478F6FF"), ("Purple", "#8E5CF6FF"), ("Pink", "#E8508BFF"), ("Red", "#E5484DFF"),
        ("Orange", "#F0883EFF"), ("Yellow", "#D9A400FF"), ("Green", "#34A853FF"), ("Teal", "#1AA5A5FF"),
        ("Brown", "#9C6B45FF"), ("Gray", "#7A7F87FF"),
    ]
    static let symbols = [
        "folder.fill", "book.closed.fill", "books.vertical.fill", "graduationcap.fill", "pencil.and.outline",
        "doc.text.fill", "newspaper.fill", "building.columns.fill", "globe.europe.africa.fill", "flask.fill",
        "function", "heart.fill", "star.fill", "flag.fill", "briefcase.fill", "tray.full.fill",
    ]

    static func color(_ hex: String?) -> Color {
        hex.flatMap { UIColor(hex: $0) }.map { Color(uiColor: $0) } ?? .accentColor
    }
}

/// Name, color and icon of a folder.
private struct FolderCustomizeView: View {
    let folder: LibraryFolder
    let save: (String, String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorHex: String?
    @State private var symbol: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Folder name", text: $name)
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                        swatch(nil, name: "Standard")
                        ForEach(FolderLook.colors, id: \.hex) { c in swatch(c.hex, name: c.name) }
                    }
                    .padding(.vertical, 6)
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                        ForEach(FolderLook.symbols, id: \.self) { s in
                            let on = (symbol ?? "folder.fill") == s
                            Button {
                                symbol = s == "folder.fill" ? nil : s
                            } label: {
                                Image(systemName: s)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(on ? FolderLook.color(colorHex) : Color.secondary)
                                    .frame(width: 44, height: 44)
                                    .background(on ? FolderLook.color(colorHex).opacity(0.16) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(s)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("Customize folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save(name, colorHex, symbol)
                        dismiss()
                    }
                }
            }
            .onAppear {
                name = folder.name
                colorHex = folder.colorHex
                symbol = folder.symbol
            }
        }
    }

    private func swatch(_ hex: String?, name: String) -> some View {
        let on = colorHex == hex
        return Button {
            colorHex = hex
        } label: {
            Circle()
                .fill(FolderLook.color(hex))
                .frame(width: 32, height: 32)
                .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0.8 : 0), lineWidth: 2.5).padding(-4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
