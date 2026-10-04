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
            HStack(spacing: 12) {
                Picker("Vista", selection: Binding(
                    get: { model.selectedCollectionID },
                    set: { model.selectCollection($0) })) {
                    Text("Cronologia").tag(Int64?.none)
                    ForEach(model.collections) { collection in
                        if let id = collection.id {
                            Text(collection.name).tag(Optional(id))
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Cerca negli appunti", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .onChange(of: model.searchText) { _, query in
                        model.updateSearch(query)
                    }

                Picker("Conservazione", selection: $model.retentionPolicy) {
                    ForEach(ClipboardRetentionPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Menu {
                    Button("Nuova raccolta", systemImage: "folder.badge.plus") {
                        newCollectionName = ""
                        isCreatingCollection = true
                    }
                    if model.selectedCollectionID != nil {
                        Divider()
                        Button("Elimina raccolta", systemImage: "trash", role: .destructive) {
                            isConfirmingCollectionDeletion = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
            .padding()

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            if model.displayedItems.isEmpty {
                ContentUnavailableView(
                    model.searchText.isEmpty
                        ? (model.selectedCollectionID == nil ? "Cronologia vuota" : "Raccolta vuota")
                        : "Nessun risultato",
                    systemImage: model.searchText.isEmpty ? "clipboard" : "magnifyingglass",
                    description: Text(
                        model.searchText.isEmpty
                            ? "Copia testo o un link in un’altra app per salvarlo qui."
                            : "Prova con un’altra parola."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pillState.isCompact {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 10) {
                        ForEach(model.displayedItems) { item in
                            ClipboardItemRow(
                                item: item,
                                collections: model.collections,
                                onMove: { model.move(item, to: $0) },
                                onRemoveFromHistory: { model.removeFromHistory(item) },
                                onDelete: { model.deletePermanently(item) })
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .scrollIndicators(.hidden)
            } else {
                List(model.displayedItems) { item in
                    ClipboardItemRow(
                        item: item,
                        collections: model.collections,
                        onMove: { model.move(item, to: $0) },
                        onRemoveFromHistory: { model.removeFromHistory(item) },
                        onDelete: { model.deletePermanently(item) })
                }
                .listStyle(.inset)
            }
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

private struct ClipboardItemRow: View {
    let item: ClipboardItem
    let collections: [ClipboardCollection]
    let onMove: (Int64?) -> Void
    let onRemoveFromHistory: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == .link ? "link" : "text.alignleft")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? item.content)
                    .lineLimit(5)
                    .font(.body)

                if item.title != nil || item.kind == .link {
                    Text(item.content)
                        .lineLimit(5)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let source = item.sourceAppBundleID {
                    Text(source)
                        .lineLimit(1)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Text(item.lastCopiedAt, style: .time)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contextMenu {
            if !collections.isEmpty {
                Menu("Assegna a raccolta") {
                    ForEach(collections) { collection in
                        if let id = collection.id {
                            Button(collection.name) { onMove(id) }
                        }
                    }
                }
                if item.collectionID != nil {
                    Button("Rimuovi dalla raccolta") { onMove(nil) }
                }
            }
            if item.isInHistory {
                Button("Rimuovi dalla cronologia", systemImage: "clock.badge.xmark") {
                    onRemoveFromHistory()
                }
            }
            Button("Elimina definitivamente", systemImage: "trash", role: .destructive) {
                onDelete()
            }
        }
    }
}

#Preview {
    ContentView(store: nil)
}
