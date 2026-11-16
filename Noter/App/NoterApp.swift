import SwiftUI

@main
struct NoterApp: App {
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .onOpenURL { url in
                    // "Open in Noter" from Files / Share sheet.
                    Task { @MainActor in await library.importPDFs([url]) }
                }
        }
    }
}
