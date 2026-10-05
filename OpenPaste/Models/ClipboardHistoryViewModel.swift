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
    private(set) var sourceApplicationBundleIDs: [String] = []
    private(set) var historyLimit = 100
    private(set) var collectionLimit = 100
    private(set) var searchLimit = 100
    var searchText = ""
    var searchFilter = ClipboardFilter()
    var isShowingSearchResults = false
    var errorMessage: String?
    var retentionPolicy: ClipboardRetentionPolicy {
        didSet {
            preferencesStore.update { $0.retentionPolicy = retentionPolicy }
        }
    }

    @ObservationIgnored private let store: (any ClipboardStore)?
    var storeForUI: (any ClipboardStore)? { store }
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

        let initialHistoryLimit = historyLimit
        historyTask = Task { [weak self] in
            do {
                try await store.pruneExpiredHistory(now: .now)
                guard !Task.isCancelled else { return }
                let stream = await store.observeHistory(limit: initialHistoryLimit)
                for try await items in stream {
                    guard !Task.isCancelled, self?.observationID == id else { return }
                    self?.historyItems = items
                    self?.refreshSourceApplicationBundleIDs(for: id)
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
                    self?.refreshSourceApplicationBundleIDs(for: id)
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
        collectionLimit = 100
        collectionItemsTask?.cancel()
        collectionItemsTask = nil
        collectionObservationID = nil
        collectionItems = []
        guard let collectionID, let store else { return }

        let id = UUID()
        let limit = collectionLimit
        collectionObservationID = id
        collectionItemsTask = Task { [weak self] in
            do {
                let stream = await store.observeCollection(collectionID: collectionID, limit: limit)
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
        searchLimit = 100
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty || !searchFilter.isEmpty, store != nil else { return }

        let id = UUID()
        searchID = id
        let query = ClipboardQuery(scope: .all, text: normalizedQuery, filter: searchFilter)
        observeSearchResults(id: id, query: query, delay: searchDebounce)
    }

    private func observeSearchResults(id: UUID, query: ClipboardQuery, delay: Duration = .zero) {
        guard let store else { return }
        let limit = searchLimit
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                let stream = await store.observeItems(query: query, limit: limit)
                for try await results in stream {
                    guard !Task.isCancelled, self?.searchID == id else { return }
                    self?.searchResults = results
                }
            } catch {
                guard self?.searchID == id else { return }
                self?.report(error)
            }
        }
    }

    func showSearchField() {
        isShowingSearchResults = false
    }

    func showSearchResults() {
        isShowingSearchResults = true
    }

    func loadMoreIfNeeded(visibleIndex: Int) {
        let items = displayedItems
        guard visibleIndex >= max(0, items.count - 12), let store else { return }
        if isSearching {
            guard searchResults.count == searchLimit, let id = searchID else { return }
            searchLimit += 100
            let query = ClipboardQuery(
                scope: .all,
                text: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                filter: searchFilter)
            observeSearchResults(id: id, query: query)
        } else if let collectionID = selectedCollectionID {
            guard collectionItems.count == collectionLimit else { return }
            collectionLimit += 100
            let id = UUID()
            let limit = collectionLimit
            collectionObservationID = id
            collectionItemsTask?.cancel()
            collectionItemsTask = Task { [weak self] in
                do {
                    let stream = await store.observeCollection(collectionID: collectionID, limit: limit)
                    for try await page in stream {
                        guard !Task.isCancelled, self?.collectionObservationID == id else { return }
                        self?.collectionItems = page
                    }
                } catch {
                    guard self?.collectionObservationID == id else { return }
                    self?.report(error)
                }
            }
        } else {
            guard historyItems.count == historyLimit else { return }
            historyLimit += 100
            let id = observationID
            let limit = historyLimit
            historyTask?.cancel()
            historyTask = Task { [weak self] in
                do {
                    let stream = await store.observeHistory(limit: limit)
                    for try await page in stream {
                        guard !Task.isCancelled, self?.observationID == id else { return }
                        self?.historyItems = page
                    }
                } catch {
                    guard self?.observationID == id else { return }
                    self?.report(error)
                }
            }
        }
    }

    func clearSearch() {
        searchText = ""
        searchFilter = ClipboardFilter()
        isShowingSearchResults = false
        updateSearch("")
    }

    func setSearchFilter(_ filter: ClipboardFilter) {
        searchFilter = filter
        updateSearch(searchText)
    }

    func createCollection(named name: String, colorHex: String = "#FF3B30") {
        guard let store else { return }
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return }
        perform {
            let collection = try await store.createCollection(name: cleanedName, createdAt: .now)
            if colorHex != "#FF3B30", let id = collection.id {
                try await store.updateCollection(collectionID: id, name: cleanedName, colorHex: colorHex)
            }
            return collection
        } onSuccess: { model, collection in
            model.selectCollection(collection.id)
            model.clearSearch()
        }
    }

    func updateCollection(_ collection: ClipboardCollection, name: String, colorHex: String) {
        guard let id = collection.id, let store else { return }
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return }
        perform { try await store.updateCollection(collectionID: id, name: cleanedName, colorHex: colorHex) }
    }

    func reorderCollections(_ ids: [Int64]) {
        guard let store else { return }
        perform { try await store.reorderCollections(ids: ids) }
    }

    func deleteSelectedCollection() {
        guard let collectionID = selectedCollectionID, let store else { return }
        let policy = retentionPolicy
        perform {
            try await store.deleteCollectionPreservingItems(
                collectionID: collectionID,
                retentionPolicy: policy,
                now: .now)
        } onSuccess: { model, _ in
            model.selectCollection(nil)
        }
    }

    func move(_ item: ClipboardItem, to collectionID: Int64?) {
        move([item], to: collectionID)
    }

    func move(_ items: [ClipboardItem], to collectionID: Int64?) {
        let ids = items.compactMap(\.id)
        guard !ids.isEmpty, let store else { return }
        let policy = retentionPolicy
        perform {
            try await store.moveItems(ids: ids, to: collectionID, retentionPolicy: policy, now: .now)
        }
    }

    func reorder(_ items: [ClipboardItem], in collectionID: Int64?) {
        guard let store, let collectionID else { return }
        let ids = items.compactMap(\.id)
        guard !ids.isEmpty else { return }
        perform { try await store.reorderItems(ids: ids, collectionID: collectionID) }
    }

    func reorder(draggedIDs: [Int64], before targetID: Int64, in items: [ClipboardItem], collectionID: Int64?) {
        guard let collectionID, let store else { return }
        let policy = retentionPolicy
        perform {
            let query = ClipboardQuery(scope: .collection(collectionID))
            var currentItems: [ClipboardItem] = []
            var offset = 0
            let pageSize = 500
            while true {
                let page = try await store.fetchItems(query: query, limit: pageSize, offset: offset)
                currentItems.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += page.count
            }
            let currentIDs = Set(currentItems.compactMap(\.id))
            let incomingIDs = draggedIDs.filter { !currentIDs.contains($0) }
            if !incomingIDs.isEmpty {
                try await store.moveItems(ids: incomingIDs, to: collectionID, retentionPolicy: policy, now: .now)
                currentItems = []
                offset = 0
                while true {
                    let page = try await store.fetchItems(query: query, limit: pageSize, offset: offset)
                    currentItems.append(contentsOf: page)
                    if page.count < pageSize { break }
                    offset += page.count
                }
            }
            var orderedIDs = currentItems.compactMap(\.id)
            let moving = orderedIDs.filter(draggedIDs.contains)
            orderedIDs.removeAll(where: draggedIDs.contains)
            guard let targetIndex = orderedIDs.firstIndex(of: targetID) else { return }
            orderedIDs.insert(contentsOf: moving, at: targetIndex)
            try await store.reorderItems(ids: orderedIDs, collectionID: collectionID)
        }
    }

    private func reorderItems(_ ids: [Int64], in collectionID: Int64) {
        guard let store, !ids.isEmpty else { return }
        perform { try await store.reorderItems(ids: ids, collectionID: collectionID) }
    }

    func clearHistory() {
        guard let store else { return }
        perform { try await store.clearHistory() }
    }

    func removeFromHistory(_ item: ClipboardItem) {
        removeFromHistory([item])
    }

    func removeFromHistory(_ items: [ClipboardItem]) {
        let ids = items.compactMap(\.id)
        guard let store, !ids.isEmpty else { return }
        perform {
            for id in ids { try await store.removeFromHistory(itemID: id) }
        }
    }

    func deletePermanently(_ item: ClipboardItem) {
        deletePermanently([item])
    }

    func deletePermanently(_ items: [ClipboardItem]) {
        let ids = items.compactMap(\.id)
        guard let store, !ids.isEmpty else { return }
        perform {
            for id in ids { try await store.deletePermanently(itemID: id) }
        }
    }

    func rename(_ item: ClipboardItem, title: String?) {
        guard let id = item.id, let store else { return }
        perform { try await store.renameItem(itemID: id, title: title) }
    }

    func updateText(_ item: ClipboardItem, content: String, language: String? = nil) {
        guard let id = item.id, let store else { return }
        perform { try await store.updateText(itemID: id, content: content, language: language) }
    }

    func updatePayload(_ item: ClipboardItem, payload: ClipboardPayload) async throws {
        guard let id = item.id, let store else { throw ClipboardStoreError.unsupportedOperation }
        try await store.updatePayload(itemID: id, payload: payload)
    }

    func createText(_ content: String, in collectionID: Int64? = nil) {
        guard let store else { return }
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let policy = retentionPolicy
        perform {
            let recorded = try await store.recordCopy(
                ClipboardPayload(kind: .text, content: cleaned),
                sourceAppBundleID: nil,
                copiedAt: .now,
                retentionPolicy: policy)
            guard let item = recorded, let id = item.id else { return recorded }
            if let collectionID {
                try await store.moveItems(ids: [id], to: collectionID, retentionPolicy: policy, now: .now)
            }
            return item
        }
    }

    func loadAllItemsForCurrentView() async -> [ClipboardItem] {
        guard let store else { return displayedItems }
        let requestedSearchState = isSearching
        let requestedText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedFilter = searchFilter
        let requestedCollectionID = selectedCollectionID
        let query: ClipboardQuery
        if requestedSearchState {
            query = ClipboardQuery(scope: .all, text: requestedText, filter: requestedFilter)
        } else if let requestedCollectionID {
            query = ClipboardQuery(scope: .collection(requestedCollectionID))
        } else {
            query = ClipboardQuery(scope: .history)
        }

        var all: [ClipboardItem] = []
        let pageSize = 500
        var offset = 0
        do {
            while true {
                let page = try await store.fetchItems(query: query, limit: pageSize, offset: offset)
                all.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += page.count
            }
        } catch {
            report(error)
            return displayedItems
        }

        guard isSearching == requestedSearchState,
              searchText.trimmingCharacters(in: .whitespacesAndNewlines) == requestedText,
              searchFilter == requestedFilter,
              selectedCollectionID == requestedCollectionID
        else { return displayedItems }

        switch query.scope {
        case .history: historyItems = all
        case .collection: collectionItems = all
        case .all: searchResults = all
        }
        return all
    }

    func classify(_ item: ClipboardItem, as kind: ClipboardItemKind, language: String? = nil) {
        guard let id = item.id, let store else { return }
        perform { try await store.setItemKind(itemID: id, kind: kind, language: language) }
    }

    func moveIDs(_ ids: [Int64], to collectionID: Int64?) {
        guard let store, !ids.isEmpty else { return }
        let policy = retentionPolicy
        perform { try await store.moveItems(ids: ids, to: collectionID, retentionPolicy: policy, now: .now) }
    }

    func importPayload(_ payload: ClipboardPayload) {
        importPayload(payload, to: nil)
    }

    func importPayload(_ payload: ClipboardPayload, to collectionID: Int64?) {
        guard let store else { return }
        let policy = retentionPolicy
        perform {
            let recorded = try await store.recordCopy(
                payload,
                sourceAppBundleID: nil,
                copiedAt: .now,
                retentionPolicy: policy)
            guard let item = recorded, let id = item.id else { return recorded }
            if let collectionID {
                try await store.moveItems(ids: [id], to: collectionID, retentionPolicy: policy, now: .now)
            }
            return item
        }
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !searchFilter.isEmpty
    }

    var displayedItems: [ClipboardItem] {
        isSearching
            ? searchResults
            : (selectedCollectionID == nil ? historyItems : collectionItems)
    }

    var displayedTitle: String {
        guard let selectedCollectionID,
              let collection = collections.first(where: { $0.id == selectedCollectionID })
        else { return "Cronologia" }
        return collection.name
    }

    private func refreshSourceApplicationBundleIDs(for observation: UUID) {
        guard let store else { return }
        Task { [weak self] in
            do {
                let bundleIDs = try await store.sourceApplicationBundleIDs()
                guard !Task.isCancelled, self?.observationID == observation else { return }
                self?.sourceApplicationBundleIDs = bundleIDs
            } catch {
                guard self?.observationID == observation else { return }
                self?.report(error)
            }
        }
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
