import SwiftUI

@MainActor
@main
struct OpenPasteApp: App {
    private let store: (any ClipboardStore)?
    private let startupError: String?

    init() {
        do {
            let database = try AppDatabase.openDefault()
            let repository = ClipboardRepository(database: database)
            store = repository
            ClipboardCaptureService.shared.start(store: repository)
            startupError = nil
        } catch {
            store = nil
            startupError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, startupError: startupError)
        }
    }
}
