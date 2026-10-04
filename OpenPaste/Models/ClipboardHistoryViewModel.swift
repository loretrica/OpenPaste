import Foundation
import Observation

@MainActor
@Observable
final class ClipboardHistoryViewModel {
    var historyItems: [ClipboardItem] = []
    var collectionItems: [ClipboardItem] = []
    var collections: [ClipboardCollection] = []
    var selectedCollectionID: Int64?
    var searchResults: [ClipboardItem] = []
    var searchText = ""
    var errorMessage: String?
    var retentionPolicy: ClipboardRetentionPolicy {
        didSet {
            var preferences = preferencesStore.preferences
            preferences.retentionPolicy = retentionPolicy
            preferencesStore.save(preferences)
        }
    }

    @ObservationIgnored private let store: (any ClipboardStore)?
    @ObservationIgnored private let preferencesStore: any PreferencesStore
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var collectionsTask: Task<Void, Never>?
    @ObservationIgnored private var collectionItemsTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(
        store: (any ClipboardStore)?,
        startupError: String? = nil,
        preferencesStore: any PreferencesStore = UserDefaultsPreferencesStore.shared
    ) {
        self.store = store
        self.preferencesStore = preferencesStore
        self.errorMessage = startupError
        self.retentionPolicy = preferencesStore.preferences.retentionPolicy
    }

    func start() {
        guard historyTask == nil, let store else { return }
        historyTask = Task {
            do {
                try await store.pruneExpiredHistory(now: .now)
                let stream = await store.observeHistory(limit: 100)
                for try await items in stream {
                    historyItems = items
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        collectionsTask = Task {
            do {
                let stream = await store.observeCollections()
                for try await updatedCollections in stream {
                    collections = updatedCollections
                    if let selectedCollectionID,
                       !updatedCollections.contains(where: { $0.id == selectedCollectionID }) {
                        selectCollection(nil)
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectCollection(_ collectionID: Int64?) {
        selectedCollectionID = collectionID
        collectionItemsTask?.cancel()
        collectionItems = []
        guard let collectionID, let store else { return }

        collectionItemsTask = Task {
            do {
                let stream = await store.observeCollection(collectionID: collectionID, limit: 100)
                for try await items in stream {
                    collectionItems = items
                }
            } catch is CancellationError {
                // Selection changed.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func updateSearch(_ query: String) {
        searchTask?.cancel()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedQuery.isEmpty, let store else {
            searchResults = []
            return
        }

        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(100))
                let results = try await store.search(
                    query: normalizedQuery,
                    limit: 100,
                    offset: 0)
                guard !Task.isCancelled else { return }
                searchResults = results
            } catch is CancellationError {
                // A newer query superseded this one.
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func createCollection(named name: String) {
        guard let store else { return }
        Task {
            do {
                let collection = try await store.createCollection(name: name, createdAt: .now)
                selectCollection(collection.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteSelectedCollection() {
        guard let collectionID = selectedCollectionID, let store else { return }
        Task {
            do {
                try await store.removeCollection(collectionID: collectionID)
                selectCollection(nil)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func move(_ item: ClipboardItem, to collectionID: Int64?) {
        guard let itemID = item.id, let store else { return }
        Task {
            do {
                try await store.moveToCollection(itemID: itemID, collectionID: collectionID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func removeFromHistory(_ item: ClipboardItem) {
        guard let itemID = item.id, let store else { return }
        Task {
            do {
                try await store.removeFromHistory(itemID: itemID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deletePermanently(_ item: ClipboardItem) {
        guard let itemID = item.id, let store else { return }
        Task {
            do {
                try await store.deletePermanently(itemID: itemID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var displayedItems: [ClipboardItem] {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return searchResults
        }
        return selectedCollectionID == nil ? historyItems : collectionItems
    }

    var displayedTitle: String {
        guard let selectedCollectionID,
              let collection = collections.first(where: { $0.id == selectedCollectionID })
        else {
            return "Cronologia"
        }
        return collection.name
    }

    deinit {
        historyTask?.cancel()
        collectionsTask?.cancel()
        collectionItemsTask?.cancel()
        searchTask?.cancel()
    }
}
