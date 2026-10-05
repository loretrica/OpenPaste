import AppKit
import SwiftUI

@MainActor
struct ContentView: View {
    @State private var model: ClipboardHistoryViewModel
    @State private var pillState: PillWindowState
    @State private var selection = ClipboardSelectionState()
    @State private var isSearchFocused = false
    @State private var searchPanel: ClipboardSearchPanel = .field
    @State private var isCreatingCollection = false
    @State private var editingCollection: ClipboardCollection?
    @State private var isConfirmingCollectionDeletion = false
    @State private var isConfirmingHistoryDeletion = false
    @State private var isConfirmingItemDeletion = false
    @State private var pendingDeletion: [ClipboardItem] = []
    @State private var newCollectionName = ""
    @State private var editedCollectionName = ""
    @State private var collectionColor = "#FF3B30"
    @State private var editingItem: ClipboardItem?
    @State private var renamingItem: ClipboardItem?
    @State private var editedItemTitle = ""
    @State private var isShowingPreview = false
    @State private var isCreatingText = false
    @State private var newText = ""
    private let actions: ClipboardUIActions
    private let onDismiss: () -> Void

    init(
        store: (any ClipboardStore)?,
        startupError: String? = nil,
        preferencesStore: any PreferencesStore = UserDefaultsPreferencesStore.shared,
        pillState: PillWindowState = PillWindowState(),
        actions: ClipboardUIActions = ClipboardUIActions(),
        onDismiss: @escaping () -> Void = {}
    ) {
        _model = State(initialValue: ClipboardHistoryViewModel(
            store: store,
            startupError: startupError,
            preferencesStore: preferencesStore))
        _pillState = State(initialValue: pillState)
        self.actions = actions
        self.onDismiss = onDismiss
    }

    private var activeItem: ClipboardItem? {
        guard let id = selection.activeID else { return nil }
        return model.displayedItems.first(where: { $0.id == id })
    }

    private var selectedItems: [ClipboardItem] {
        model.displayedItems.filter { item in item.id.map(selection.selectedIDs.contains) ?? false }
    }

    var body: some View {
        VStack(spacing: 12) {
            toolbarView

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }

            historyItemsView
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: pillState.isCompact ? 72 : 40, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: pillState.isCompact ? 72 : 40, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .overlay(alignment: .bottom) {
            if let message = actions.status?.message {
                Text(message)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipboard.pill")
        .animation(.easeOut(duration: 0.18), value: actions.status?.message)
        .background {
            ClipboardKeyboardRouter(isSearchFocused: isSearchFocused, onCommand: handleKeyboardCommand)
                .frame(width: 0, height: 0)
        }
        .onChange(of: model.displayedItems) { _, items in selection.setVisibleItems(items) }
        .onChange(of: model.searchFilter) { _, _ in model.updateSearch(model.searchText) }
        .onChange(of: searchPanel) { _, mode in
            if mode == .results { isSearchFocused = false; model.showSearchResults() }
            else { model.showSearchField() }
        }
        .onExitCommand(perform: dismissLayer)
        .task {
            model.start()
            selection.setVisibleItems(model.displayedItems)
        }
        .onDisappear { model.stop(); actions.holdInteraction(false) }
        .sheet(isPresented: $isCreatingCollection) { collectionEditor(isNew: true) }
        .sheet(isPresented: $isCreatingText) { newTextEditor }
        .sheet(item: $editingCollection) { _ in collectionEditor(isNew: false) }
        .sheet(item: $renamingItem) { item in itemRenameEditor(item) }
        .sheet(item: $editingItem) { item in
            ClipboardTextEditor(item: item, store: store, onSave: { payload in
                try await model.updatePayload(item, payload: payload)
            }, onSessionChanged: actions.holdInteraction)
        }
        .sheet(isPresented: $isShowingPreview) {
            if let activeItem { ClipboardItemPreviewWindow(item: activeItem, store: store, onSessionChanged: actions.holdInteraction) }
        }
        .confirmationDialog(
            "Eliminare la raccolta?",
            isPresented: $isConfirmingCollectionDeletion,
            titleVisibility: .visible) {
                Button("Elimina raccolta", role: .destructive) { model.deleteSelectedCollection() }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Gli elementi salvati resteranno nella cronologia secondo la regola di conservazione.")
            }
        .confirmationDialog(
            "Svuotare la cronologia?",
            isPresented: $isConfirmingHistoryDeletion,
            titleVisibility: .visible) {
                Button("Svuota cronologia", role: .destructive) { model.clearHistory() }
                Button("Annulla", role: .cancel) {}
            }
        .confirmationDialog(
            pendingDeletion.count > 1 ? "Eliminare \(pendingDeletion.count) elementi?" : "Eliminare l’elemento?",
            isPresented: $isConfirmingItemDeletion,
            titleVisibility: .visible) {
                Button("Elimina definitivamente", role: .destructive) {
                    model.deletePermanently(pendingDeletion)
                    pendingDeletion = []
                    selection.clear()
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Questa operazione elimina gli elementi selezionati.")
            }
        .onChange(of: isConfirmingCollectionDeletion) { _, shown in actions.holdInteraction(shown) }
        .onChange(of: isConfirmingHistoryDeletion) { _, shown in actions.holdInteraction(shown) }
        .onChange(of: isConfirmingItemDeletion) { _, shown in actions.holdInteraction(shown) }
    }

    private var toolbarView: some View {
        ClipboardHistoryToolbar(
            collections: model.collections,
            sourceAppBundleIDs: model.sourceApplicationBundleIDs,
            selectedCollectionID: Binding(
                get: { model.selectedCollectionID },
                set: { model.selectCollection($0); model.clearSearch(); selection.clear(); isSearchFocused = false; searchPanel = .field }),
            searchText: $model.searchText,
            retentionPolicy: $model.retentionPolicy,
            searchFilter: $model.searchFilter,
            searchPanel: $searchPanel,
            isSearchFocused: $isSearchFocused,
            onSearchChanged: model.updateSearch,
            onCreateCollection: beginCollectionCreation,
            onEditCollection: beginCollectionEdit,
            onDeleteCollection: { isConfirmingCollectionDeletion = true },
            onClearHistory: { isConfirmingHistoryDeletion = true },
            onReorderCollections: model.reorderCollections,
            onMoveItems: model.moveIDs,
            onImportPayload: { payload, collectionID in model.importPayload(payload, to: collectionID) },
            actions: actions)
    }

    private var historyItemsView: some View {
        ClipboardHistoryItems(
            items: model.displayedItems,
            collections: model.collections,
            isCompact: pillState.isCompact,
            selectedCollectionID: model.selectedCollectionID,
            isSearching: model.isSearching,
            activeID: selection.activeID,
            selectedIDs: selection.selectedIDs,
            store: store,
            onSelect: { item, flags in
                isSearchFocused = false
                if model.isSearching { searchPanel = .results; model.showSearchResults() }
                selection.select(item, modifiers: flags)
            },
            onActivate: { item in actions.paste(item, false) },
            onMove: { items, collectionID in model.move(items, to: collectionID); selection.clear() },
            onMoveIDs: { ids, collectionID in model.moveIDs(ids, to: collectionID); selection.clear() },
            onDelete: { items in
                pendingDeletion = items
                isConfirmingItemDeletion = true
            },
            onRename: { item, title in model.rename(item, title: title) },
            onEdit: { editingItem = $0 },
            onOpen: actions.open,
            onPreview: { item in
                selection.select(item, modifiers: [])
                if item.kind == .image || item.kind == .file { actions.preview(item) }
                else { isShowingPreview = true }
            },
            onClassify: { item, kind, language in model.classify(item, as: kind, language: language) },
            onSessionChanged: actions.holdInteraction,
            onImport: { model.importPayload($0, to: model.selectedCollectionID) },
            onNearEnd: model.loadMoreIfNeeded,
            onReorderItems: { ids, targetID in
                if let collectionID = model.selectedCollectionID {
                    model.reorder(draggedIDs: ids, before: targetID, in: model.displayedItems, collectionID: collectionID)
                } else {
                    let visibleIDs = Set(model.displayedItems.compactMap { $0.id })
                    model.moveIDs(ids.filter { !visibleIDs.contains($0) }, to: nil)
                }
            })
    }

    @ViewBuilder
    private func collectionEditor(isNew: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Nuova raccolta" : "Modifica raccolta").font(.headline)
            TextField("Nome della raccolta", text: isNew ? $newCollectionName : $editedCollectionName)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                ForEach(["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#007AFF", "#5856D6", "#AF52DE", "#FF2D55"], id: \.self) { hex in
                    Button { collectionColor = hex } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 23, height: 23)
                            .overlay(Circle().strokeBorder(.white, lineWidth: collectionColor == hex ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { isCreatingCollection = false; editingCollection = nil }
                Button(isNew ? "Crea" : "Salva") {
                    if isNew {
                        model.createCollection(named: newCollectionName, colorHex: collectionColor)
                    } else if let editingCollection {
                        model.updateCollection(editingCollection, name: editedCollectionName, colorHex: collectionColor)
                    }
                    isCreatingCollection = false
                    editingCollection = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 330)
        .onAppear { actions.holdInteraction(true) }
        .onDisappear { actions.holdInteraction(false) }
    }

    private var store: (any ClipboardStore)? { model.storeForUI }

    private func beginItemRename(_ item: ClipboardItem) {
        editedItemTitle = item.customTitle ?? item.title ?? ""
        renamingItem = item
    }

    @ViewBuilder
    private func itemRenameEditor(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rinomina elemento").font(.headline)
            TextField("Nome", text: $editedItemTitle).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { renamingItem = nil }
                Button("Salva") {
                    let title = editedItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.rename(item, title: title.isEmpty ? nil : title)
                    renamingItem = nil
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { actions.holdInteraction(true) }
        .onDisappear { actions.holdInteraction(false) }
    }

    private var newTextEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nuovo testo").font(.headline)
            TextEditor(text: $newText)
                .frame(minWidth: 540, minHeight: 340)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { isCreatingText = false }
                Button("Salva") {
                    model.createText(newText, in: model.selectedCollectionID)
                    isCreatingText = false
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .onAppear { actions.holdInteraction(true) }
        .onDisappear { actions.holdInteraction(false) }
    }

    private func beginCollectionCreation() {
        newCollectionName = ""
        collectionColor = "#FF3B30"
        isCreatingCollection = true
    }

    private func beginCollectionEdit(_ collection: ClipboardCollection) {
        editedCollectionName = collection.name
        collectionColor = collection.colorHex
        editingCollection = collection
    }

    private func handleKeyboardCommand(_ command: ClipboardKeyboardCommand) {
        let items = model.displayedItems
        switch command {
        case .previous: selection.moveActive(by: -1)
        case .next: selection.moveActive(by: 1)
        case .first:
            Task {
                let allItems = await model.loadAllItemsForCurrentView()
                selection.setVisibleItems(allItems)
                selection.moveActive(toFirst: true)
            }
        case .last:
            Task {
                let allItems = await model.loadAllItemsForCurrentView()
                selection.setVisibleItems(allItems)
                selection.moveActive(toFirst: false)
            }
        case .extendPrevious: selection.moveActive(by: -1, extending: true)
        case .extendNext: selection.moveActive(by: 1, extending: true)
        case .previousCollection: moveCollection(by: -1)
        case .nextCollection: moveCollection(by: 1)
        case .selectAll:
            Task {
                let allItems = await model.loadAllItemsForCurrentView()
                selection.setVisibleItems(allItems)
                selection.selectAll()
            }
        case .copy:
            if let activeItem { actions.copy(activeItem) }
        case .preview:
            if let activeItem {
                if activeItem.kind == .image || activeItem.kind == .file {
                    actions.preview(activeItem)
                } else {
                    isShowingPreview = true
                }
            }
        case .open:
            if isSearchFocused {
                isSearchFocused = false
                model.showSearchResults()
                searchPanel = .results
            } else if let activeItem {
                actions.paste(activeItem, false)
            }
        case .rename:
            if let activeItem { beginItemRename(activeItem) }
        case .edit:
            if let activeItem {
                if activeItem.kind == .text || activeItem.kind == .code { editingItem = activeItem }
            }
        case .newText:
            newText = ""
            isCreatingText = true
        case .newCollection:
            beginCollectionCreation()
        case .paste(let plainText):
            if let activeItem { actions.paste(activeItem, plainText) }
        case .quickPaste(let index, let plainText):
            guard index > 0, index <= items.count else { return }
            let target = items[index - 1]
            selection.select(target, modifiers: [])
            actions.paste(target, plainText)
        case .search:
            isSearchFocused = true
            searchPanel = .field
            model.showSearchField()
        case .tab:
            if searchPanel == .field {
                searchPanel = .results
                isSearchFocused = false
                model.showSearchResults()
            } else {
                searchPanel = .field
                isSearchFocused = true
                model.showSearchField()
            }
        case .delete:
            let targets = selectedItems.isEmpty ? [activeItem].compactMap { $0 } : selectedItems
            if model.selectedCollectionID != nil && !model.isSearching {
                model.move(targets, to: nil)
            } else {
                model.removeFromHistory(targets)
            }
            selection.clear()
        case .dismiss:
            dismissLayer()
        case .searchText(let text):
            isSearchFocused = true
            model.searchText += text
            searchPanel = .field
            model.showSearchField()
        }
    }

    private func moveCollection(by offset: Int) {
        let ids: [Int64?] = [nil] + model.collections.compactMap(\.id).map(Optional.some)
        let current = ids.firstIndex(of: model.selectedCollectionID) ?? 0
        let index = min(max(current + offset, 0), ids.count - 1)
        model.selectCollection(ids[index])
        selection.clear()
    }

    private func dismissLayer() {
        if isShowingPreview {
            isShowingPreview = false
        } else if editingItem != nil {
            editingItem = nil
        } else if editingCollection != nil {
            editingCollection = nil
        } else if isCreatingText {
            isCreatingText = false
        } else if isCreatingCollection {
            isCreatingCollection = false
        } else if isSearchFocused || model.isSearching {
            isSearchFocused = false
            model.clearSearch()
            searchPanel = .field
        } else {
            onDismiss()
        }
    }
}

#Preview("History · light") {
    ContentView(store: nil).preferredColorScheme(.light)
}

#Preview("History · dark") {
    ContentView(store: nil).preferredColorScheme(.dark)
}
