#if DEBUG
import SwiftUI

@MainActor
private final class ClipboardPreviewPreferences: PreferencesStore {
    var preferences = AppPreferences.default
    func save(_ preferences: AppPreferences) { self.preferences = preferences }
}

@MainActor
struct ClipboardPanelPreview: View {
    @State private var repository: ClipboardRepository?
    @State private var preferences = ClipboardPreviewPreferences()
    @State private var pillState = PillWindowState()
    @State private var error: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [.orange.opacity(0.7), .pink.opacity(0.3), .blue.opacity(0.3)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let repository {
                ContentView(store: repository, preferencesStore: preferences, pillState: pillState)
                    .frame(height: 360)
                    .padding(24)
            } else if let error {
                Text(error)
            } else {
                ProgressView()
            }
        }
        .frame(width: 1440, height: 420)
        .task {
            guard repository == nil else { return }
            do {
                let store = try ClipboardDemoData.makeRepository()
                try await ClipboardDemoData.populate(store)
                pillState.update(forHeight: 360)
                repository = store
            } catch { self.error = error.localizedDescription }
        }
    }
}

#Preview("Pillola chiara") {
    ClipboardPanelPreview().preferredColorScheme(.light)
}

#Preview("Pillola scura") {
    ClipboardPanelPreview().preferredColorScheme(.dark)
}
#endif
