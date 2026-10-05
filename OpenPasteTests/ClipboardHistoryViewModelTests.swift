import Foundation
import Testing
@testable import OpenPaste

@MainActor
struct ClipboardHistoryViewModelTests {
    @Test
    func activeObservationsDoNotRetainTheViewModel() async throws {
        let store = ClipboardRepository(database: try AppDatabase.makeInMemory())
        _ = try await store.recordCopy("Initial copy", sourceAppBundleID: nil, retentionPolicy: .forever)
        var model: ClipboardHistoryViewModel? = ClipboardHistoryViewModel(
            store: store,
            preferencesStore: MemoryPreferencesStore())
        let reference = WeakHistoryModelReference(model)
        model?.start()
        try await waitUntil { model?.historyItems.count == 1 }

        model = nil
        #expect(reference.model == nil)
    }

    @Test
    func observationsCanStopAndRestartWithTheSelectedCollection() async throws {
        let store = ClipboardRepository(database: try AppDatabase.makeInMemory())
        let collection = try await store.createCollection(name: "Saved")
        let collectionID = try #require(collection.id)
        let first = try #require(try await store.recordCopy(
            "First", sourceAppBundleID: nil, retentionPolicy: .forever))
        try await store.moveToCollection(itemID: try #require(first.id), collectionID: collectionID)
        let model = ClipboardHistoryViewModel(store: store, preferencesStore: MemoryPreferencesStore())
        defer { model.stop() }

        model.start()
        model.start()
        try await waitUntil { model.historyItems.count == 1 && model.collections.count == 1 }
        model.selectCollection(collectionID)
        try await waitUntil { model.collectionItems.count == 1 }
        model.stop()

        let second = try #require(try await store.recordCopy(
            "Second", sourceAppBundleID: nil, retentionPolicy: .forever))
        try await store.moveToCollection(itemID: try #require(second.id), collectionID: collectionID)
        #expect(model.historyItems.count == 1)

        model.start()
        try await waitUntil { model.historyItems.count == 2 && model.collectionItems.count == 2 }
        #expect(model.selectedCollectionID == collectionID)
        #expect(model.errorMessage == nil)
    }

    @Test
    func clearingSearchDiscardsPendingResultsAndUsesHistory() async throws {
        let store = ClipboardRepository(database: try AppDatabase.makeInMemory())
        _ = try await store.recordCopy("Alpha content", sourceAppBundleID: nil, retentionPolicy: .forever)
        _ = try await store.recordCopy("Beta content", sourceAppBundleID: nil, retentionPolicy: .forever)
        let model = ClipboardHistoryViewModel(
            store: store, preferencesStore: MemoryPreferencesStore(), searchDebounce: .milliseconds(10))
        defer { model.stop() }
        model.start()
        try await waitUntil { model.historyItems.count == 2 }

        model.searchText = "Alpha"
        model.updateSearch(model.searchText)
        model.showSearchResults()
        try await waitUntil { model.searchResults.count == 1 }
        #expect(model.displayedItems.first?.content == "Alpha content")

        model.searchText = "Beta"
        model.updateSearch(model.searchText)
        #expect(model.searchResults.isEmpty)
        model.searchText = "  \n "
        model.updateSearch(model.searchText)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!model.isSearching)
        #expect(model.searchResults.isEmpty)
        #expect(model.displayedItems.count == 2)
        #expect(model.errorMessage == nil)
    }

    @Test
    func returningToHistoryDiscardsCollectionObservation() async throws {
        let store = ClipboardRepository(database: try AppDatabase.makeInMemory())
        let collection = try await store.createCollection(name: "Saved")
        let collectionID = try #require(collection.id)
        let first = try #require(try await store.recordCopy(
            "Collected", sourceAppBundleID: nil, retentionPolicy: .forever))
        try await store.moveToCollection(itemID: try #require(first.id), collectionID: collectionID)
        let model = ClipboardHistoryViewModel(store: store, preferencesStore: MemoryPreferencesStore())
        defer { model.stop() }
        model.start()
        try await waitUntil { model.collections.count == 1 }
        model.selectCollection(collectionID)
        try await waitUntil { model.collectionItems.count == 1 }
        model.selectCollection(nil)
        _ = try await store.recordCopy("History only", sourceAppBundleID: nil, retentionPolicy: .forever)
        try await waitUntil { model.historyItems.count == 2 }

        #expect(model.collectionItems.isEmpty)
        #expect(model.selectedCollectionID == nil)
        #expect(model.displayedItems.count == 2)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "Expected observation update before the timeout")
    }
}

@MainActor
private final class WeakHistoryModelReference {
    weak var model: ClipboardHistoryViewModel?

    init(_ model: ClipboardHistoryViewModel?) {
        self.model = model
    }
}

@MainActor
private final class MemoryPreferencesStore: PreferencesStore {
    private(set) var preferences = AppPreferences.default

    func save(_ preferences: AppPreferences) {
        self.preferences = preferences
    }
}
