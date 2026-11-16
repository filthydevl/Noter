import SwiftUI

/// The book's details for citations, filled in once per PDF. What you type here is
/// exactly what goes into the citation.
struct SourceDetailsView: View {
    @ObservedObject var session: DocumentSession
    @Environment(\.dismiss) private var dismiss
    @State private var source = SourceInfo()
    @State private var loaded = false
    @State private var looking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(originNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        looking = true
                        var s = source
                        s.origin = "guess"
                        session.saveSource(s)
                        let task = session.findSource(force: true)
                        Task { @MainActor in
                            await task?.value
                            source = session.source
                            looking = false
                        }
                    } label: {
                        if looking { ProgressView() } else { Label("Look up by DOI", systemImage: "magnifyingglass") }
                    }
                    .disabled(source.doi.trimmingCharacters(in: .whitespaces).isEmpty || looking)
                }
                Section {
                    Picker("This PDF is a", selection: $source.kind) {
                        ForEach(SourceInfo.Kind.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    field("Author(s)", $source.authors, hint: "John A. Davis; Anna Maria Rao")
                    field(source.kind == .book ? "Title" : (source.kind == .chapter ? "Chapter title" : "Article title"),
                          $source.title)
                    if source.kind == .chapter {
                        field("Book title", $source.container)
                        field("Editor(s)", $source.editors, hint: "First Last; First Last")
                    }
                    if source.kind == .article {
                        field("Journal", $source.container)
                        field("Volume", $source.volume)
                        field("Issue", $source.issue)
                    }
                } footer: {
                    Text("Names as “First Last”, several separated by a semicolon.")
                }
                Section {
                    if source.kind != .article {
                        field("Publisher", $source.publisher)
                        field("City", $source.place)
                        if source.kind == .book { field("Edition", $source.edition, hint: "2nd") }
                    }
                    field("Year", $source.year)
                    if source.kind != .book { field("Pages of the whole piece", $source.pages, hint: "440–460") }
                    field("DOI or link", $source.doi)
                }
                Section {
                    Text(Citation.plain(Citation.chicagoNote(source, page: "24")))
                        .font(.footnote)
                    Text(Citation.plain(Citation.mlaEntry(source)))
                        .font(.footnote)
                } header: {
                    Text("Preview (Chicago footnote, MLA works cited)")
                } footer: {
                    Text("The page number comes from the page a highlight is on — the number printed in the book, not the PDF's page count.")
                }
            }
            .navigationTitle("Source details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        source.origin = nil // yours now: never filled in over
                        session.saveSource(source)
                        dismiss()
                    }
                }
            }
            .onAppear {
                if !loaded {
                    source = session.source
                    loaded = true
                }
            }
        }
    }

    private var originNote: String {
        switch source.origin {
        case "crossref": "Filled in from the publisher's record for this DOI (Crossref). Change anything that's off and Save."
        case "guess": "Read off the pages (running headers, first heading, the publisher line). Check it — or look up the exact record with the DOI."
        default: "Your saved details."
        }
    }

    private func field(_ title: String, _ text: Binding<String>, hint: String = "") -> some View {
        LabeledContent(title) {
            TextField(hint, text: text)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
        }
    }
}
