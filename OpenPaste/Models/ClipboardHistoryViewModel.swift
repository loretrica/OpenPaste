import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class ClipboardHistoryViewModel {
    private(set) var historyItems: [ClipboardItem] = []
    private(set) var collectionItems: [ClipboardItem] = []
    private(set) var collections: [ClipboardCollection] = []
    private(set) var selectedCollectionID: Int64?
    private(set) var searchResults: [ClipboardItem] = []
    var searchText = ""
    var errorMessage: String?
    var retentionPolicy: ClipboardRetentionPolicy {
        didSet {
            preferencesStore.update { $0.retentionPolicy = retentionPolicy }
        }
    }

    @ObservationIgnored private let store: (any ClipboardStore)?
    @ObservationIgnored private let preferencesStore: any PreferencesStore
    @ObservationIgnored private let searchDebounce: Duration
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var collectionsTask: Task<Void, Never>?
    @ObservationIgnored private var collectionItemsTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var observationID: UUID?
    @ObservationIgnored private var collectionObservationID: UUID?
    @ObservationIgnored private var searchID: UUID?

    init(
        store: (any ClipboardStore)?,
        startupError: String? = nil,
        preferencesStore: any PreferencesStore = UserDefaultsPreferencesStore.shared,
        searchDebounce: Duration = .milliseconds(100)
    ) {
        self.store = store
        self.preferencesStore = preferencesStore
        self.searchDebounce = searchDebounce
        errorMessage = startupError
        retentionPolicy = preferencesStore.preferences.retentionPolicy
    }

    func start() {
        guard observationID == nil, let store else { return }
        let id = UUID()
        observationID = id

        historyTask = Task { [weak self] in
            do {
                try await store.pruneExpiredHistory(now: .now)
                guard !Task.isCancelled else { return }
                let stream = await store.observeHistory(limit: 100)
                for try await items in stream {
                    guard !Task.isCancelled, self?.observationID == id else { return }
                    self?.historyItems = items
                }
            } catch {
                guard self?.observationID == id else { return }
                self?.report(error)
            }
        }

        collectionsTask = Task { [weak self] in
            do {
                let stream = await store.observeCollections()
                for try await updatedCollections in stream {
                    guard !Task.isCancelled, self?.observationID == id else { return }
                    self?.updateCollections(updatedCollections)
                }
            } catch {
                guard self?.observationID == id else { return }
                self?.report(error)
            }
        }

        selectCollection(selectedCollectionID)
        updateSearch(searchText)
    }

    func stop() {
        observationID = nil
        collectionObservationID = nil
        searchID = nil
        historyTask?.cancel()
        collectionsTask?.cancel()
        collectionItemsTask?.cancel()
        searchTask?.cancel()
        historyTask = nil
        collectionsTask = nil
        collectionItemsTask = nil
        searchTask = nil
    }

    func selectCollection(_ collectionID: Int64?) {
        selectedCollectionID = collectionID
        collectionItemsTask?.cancel()
        collectionItemsTask = nil
        collectionObservationID = nil
        collectionItems = []
        guard let collectionID, let store else { return }

        let id = UUID()
        collectionObservationID = id
        collectionItemsTask = Task { [weak self] in
            do {
                let stream = await store.observeCollection(collectionID: collectionID, limit: 100)
                for try await items in stream {
                    guard !Task.isCancelled, self?.collectionObservationID == id else { return }
                    self?.collectionItems = items
                }
            } catch {
                guard self?.collectionObservationID == id else { return }
                self?.report(error)
            }
        }
    }

    func updateSearch(_ query: String) {
        searchTask?.cancel()
        searchTask = nil
        searchID = nil
        searchResults = []
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, let store else { return }

        let id = UUID()
        searchID = id
        let debounce = searchDebounce
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
                let results = try await store.search(query: normalizedQuery, limit: 100, offset: 0)
                guard !Task.isCancelled, self?.searchID == id else { return }
                self?.searchResults = results
            } catch {
                guard self?.searchID == id else { return }
                self?.report(error)
            }
        }
    }

    func createCollection(named name: String) {
        guard let store else { return }
        perform {
            try await store.createCollection(name: name, createdAt: .now)
        } onSuccess: { model, collection in
            model.selectCollection(collection.id)
        }
    }

    func deleteSelectedCollection() {
        guard let collectionID = selectedCollectionID, let store else { return }
        perform {
            try await store.removeCollection(collectionID: collectionID)
        } onSuccess: { model, _ in
            if model.selectedCollectionID == collectionID {
                model.selectCollection(nil)
            }
        }
    }

    func move(_ item: ClipboardItem, to collectionID: Int64?) {
        guard let itemID = item.id, let store else { return }
        perform { try await store.moveToCollection(itemID: itemID, collectionID: collectionID) }
    }

    func removeFromHistory(_ item: ClipboardItem) {
        guard let itemID = item.id, let store else { return }
        perform { try await store.removeFromHistory(itemID: itemID) }
    }

    func deletePermanently(_ item: ClipboardItem) {
        guard let itemID = item.id, let store else { return }
        perform { try await store.deletePermanently(itemID: itemID) }
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayedItems: [ClipboardItem] {
        isSearching ? searchResults : (selectedCollectionID == nil ? historyItems : collectionItems)
    }

    var displayedTitle: String {
        guard let selectedCollectionID,
              let collection = collections.first(where: { $0.id == selectedCollectionID })
        else { return "Cronologia" }
        return collection.name
    }

    private func updateCollections(_ updatedCollections: [ClipboardCollection]) {
        collections = updatedCollections
        if let selectedCollectionID,
           !updatedCollections.contains(where: { $0.id == selectedCollectionID }) {
            selectCollection(nil)
        }
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value,
        onSuccess: @escaping @MainActor (ClipboardHistoryViewModel, Value) -> Void = { _, _ in }
    ) {
        Task { [weak self] in
            do {
                let value = try await operation()
                guard !Task.isCancelled, let self else { return }
                onSuccess(self, value)
            } catch {
                self?.report(error)
            }
        }
    }

    private func report(_ error: Error) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        errorMessage = error.localizedDescription
    }

    deinit {
        historyTask?.cancel()
        collectionsTask?.cancel()
        collectionItemsTask?.cancel()
        searchTask?.cancel()
    }
}
