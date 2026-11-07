import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showImporter = false
    @State private var path: [UUID] = []
    @State private var pendingDelete: DocumentInfo?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 28, alignment: .top)]

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
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 36) {
                            ForEach(library.documents) { doc in
                                NavigationLink(value: doc.id) {
                                    BookCard(doc: doc)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        pendingDelete = doc
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.top, 12)
                        .padding(.bottom, 40)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Library")
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

private struct BookCard: View {
    let doc: DocumentInfo
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
                if doc.ocrPagesDone < doc.pageCount {
                    ProgressView(value: Double(doc.ocrPagesDone), total: Double(max(doc.pageCount, 1)))
                        .tint(.secondary)
                        .padding(.top, 4)
                        .accessibilityLabel("Text recognized on \(doc.ocrPagesDone) of \(doc.pageCount) pages")
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
