import SwiftUI

@MainActor
struct ContentView: View {
    @State private var model: ClipboardHistoryViewModel
    @State private var pillState: PillWindowState
    @State private var isCreatingCollection = false
    @State private var isConfirmingCollectionDeletion = false
    @State private var newCollectionName = ""
    private let onDismiss: () -> Void

    init(
        store: (any ClipboardStore)?,
        startupError: String? = nil,
        preferencesStore: any PreferencesStore = UserDefaultsPreferencesStore.shared,
        pillState: PillWindowState = PillWindowState(),
        onDismiss: @escaping () -> Void = {}
    ) {
        _model = State(
            initialValue: ClipboardHistoryViewModel(
                store: store,
                startupError: startupError,
                preferencesStore: preferencesStore))
        _pillState = State(initialValue: pillState)
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            ClipboardHistoryToolbar(
                collections: model.collections,
                selectedCollectionID: Binding(
                    get: { model.selectedCollectionID },
                    set: { model.selectCollection($0) }),
                searchText: $model.searchText,
                retentionPolicy: $model.retentionPolicy,
                onSearchChanged: model.updateSearch,
                onCreateCollection: {
                    newCollectionName = ""
                    isCreatingCollection = true
                },
                onDeleteCollection: {
                    isConfirmingCollectionDeletion = true
                })

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            ClipboardHistoryItems(
                items: model.displayedItems,
                collections: model.collections,
                isCompact: pillState.isCompact,
                selectedCollectionID: model.selectedCollectionID,
                isSearching: model.isSearching,
                onMove: { item, collectionID in model.move(item, to: collectionID) },
                onRemoveFromHistory: model.removeFromHistory,
                onDelete: model.deletePermanently)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(
            .regularMaterial,
            in: RoundedRectangle(
                cornerRadius: pillState.isCompact ? 72 : 40,
                style: .continuous))
        .overlay {
            RoundedRectangle(
                cornerRadius: pillState.isCompact ? 72 : 40,
                style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .onExitCommand(perform: onDismiss)
        .task {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
        .alert("Nuova raccolta", isPresented: $isCreatingCollection) {
            TextField("Nome", text: $newCollectionName)
            Button("Crea") {
                model.createCollection(named: newCollectionName)
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Dai un nome alla raccolta.")
        }
        .confirmationDialog(
            "Eliminare la raccolta?",
            isPresented: $isConfirmingCollectionDeletion,
            titleVisibility: .visible) {
                Button("Elimina raccolta", role: .destructive) {
                    model.deleteSelectedCollection()
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Gli elementi non presenti nella cronologia verranno eliminati definitivamente.")
            }
    }
}

#Preview {
    ContentView(store: nil)
}
