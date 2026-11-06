import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showImporter = false
    @State private var path: [UUID] = []
    @State private var pendingDelete: DocumentInfo?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.documents.isEmpty {
                    ContentUnavailableView {
                        Label("No PDFs yet", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("Import a PDF. Noter reads the text, then you can highlight with your Apple Pencil and listen to it.")
                    } actions: {
                        Button("Import PDF") { showImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(library.documents) { doc in
                            NavigationLink(value: doc.id) {
                                LibraryRow(doc: doc)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    pendingDelete = doc
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDelete = doc
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Noter")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
                Task { @MainActor in
                    let ids = await library.importPDFs(urls)
                    if ids.count == 1 { path = ids }
                }
            }
            .overlay {
                if library.importing {
                    ProgressView("Importing…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
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
            .onAppear { library.reload() }
        }
    }
}

private struct LibraryRow: View {
    let doc: DocumentInfo
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                } else {
                    Rectangle().fill(Color(.tertiarySystemFill))
                }
            }
            .frame(width: 56, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(doc.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(doc.pageCount) pages · \(doc.highlightCount) highlight\(doc.highlightCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if doc.ocrPagesDone < doc.pageCount {
                    Text("Text recognized on \(doc.ocrPagesDone) of \(doc.pageCount) pages")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
        .task(id: doc.id) {
            thumbnail = await Thumbnailer.thumbnail(for: doc.id)
        }
    }
}

enum Thumbnailer {
    static func thumbnail(for id: UUID) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            let url = Storage.thumbnailURL(id)
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) { return image }
            guard let doc = PDFDocument(url: Storage.pdfURL(id)), let page = doc.page(at: 0) else { return nil }
            let image = page.thumbnail(of: CGSize(width: 168, height: 216), for: .cropBox)
            if let data = image.jpegData(compressionQuality: 0.8) { try? data.write(to: url, options: .atomic) }
            return image
        }.value
    }
}
