import Foundation
import GRDB

enum ClipboardStoreError: LocalizedError, Sendable {
    case emptyCollectionName
    case invalidLink

    var errorDescription: String? {
        switch self {
        case .emptyCollectionName:
            "Il nome della raccolta non può essere vuoto."
        case .invalidLink:
            "Il link non è valido."
        }
    }
}

protocol ClipboardStore: Sendable {
    func recordCopy(
        _ content: String,
        sourceAppBundleID: String?,
        copiedAt: Date
    ) async throws -> ClipboardItem?

    func history(limit: Int) async throws -> [ClipboardItem]
    func collections() async throws -> [ClipboardCollection]
    func collectionItems(collectionID: Int64, limit: Int) async throws -> [ClipboardItem]
    func search(query: String, limit: Int, offset: Int) async throws -> [ClipboardItem]
    func observeHistory(limit: Int) async -> AsyncValueObservation<[ClipboardItem]>
    func observeCollections() async -> AsyncValueObservation<[ClipboardCollection]>
    func observeCollection(
        collectionID: Int64,
        limit: Int
    ) async -> AsyncValueObservation<[ClipboardItem]>

    func createCollection(name: String, createdAt: Date) async throws -> ClipboardCollection
    func moveToCollection(itemID: Int64, collectionID: Int64?) async throws
    func removeFromHistory(itemID: Int64) async throws
    func deletePermanently(itemID: Int64) async throws
    func removeCollection(collectionID: Int64) async throws
    func clearHistory() async throws
    func applyRetentionPolicy(_ policy: ClipboardRetentionPolicy, now: Date) async throws
}

protocol LinkMetadataLoading: Sendable {
    func metadata(for url: URL) async throws -> ClipboardLinkMetadata?
}

actor ClipboardRepository: ClipboardStore {
    private let database: AppDatabase
    private let metadataLoader: any LinkMetadataLoading

    init(database: AppDatabase, metadataLoader: any LinkMetadataLoading = URLSessionMetadataLoader()) {
        self.database = database
        self.metadataLoader = metadataLoader
    }

    func recordCopy(
        _ content: String,
        sourceAppBundleID: String?,
        copiedAt: Date = .now
    ) async throws -> ClipboardItem? {
        guard !content.isEmpty else { return nil }

        let classified = ClipboardContent.classify(content)
        let item = try await database.recordCopy(
            content: classified,
            sourceAppBundleID: sourceAppBundleID,
            copiedAt: copiedAt)

        guard classified.kind == .link,
              item.title == nil,
              item.linkDescription == nil,
              let canonicalURL = classified.canonicalURL,
              let url = URL(string: canonicalURL),
              let itemID = item.id
        else {
            return item
        }

        let database = self.database
        let metadataLoader = self.metadataLoader
        Task.detached {
            do {
                guard let metadata = try await metadataLoader.metadata(for: url) else { return }
                try await database.updateLinkMetadata(itemID: itemID, metadata: metadata)
            } catch {
                // The saved URL remains available if metadata loading fails.
            }
        }

        return item
    }

    func history(limit: Int) async throws -> [ClipboardItem] {
        try await database.history(limit: limit)
    }

    func collections() async throws -> [ClipboardCollection] {
        try await database.collections()
    }

    func collectionItems(collectionID: Int64, limit: Int) async throws -> [ClipboardItem] {
        try await database.collectionItems(collectionID: collectionID, limit: limit)
    }

    func search(query: String, limit: Int, offset: Int = 0) async throws -> [ClipboardItem] {
        try await database.search(query: query, limit: limit, offset: offset)
    }

    func observeHistory(limit: Int = 100) async -> AsyncValueObservation<[ClipboardItem]> {
        await database.observeHistory(limit: limit)
    }

    func observeCollections() async -> AsyncValueObservation<[ClipboardCollection]> {
        await database.observeCollections()
    }

    func observeCollection(
        collectionID: Int64,
        limit: Int = 100
    ) async -> AsyncValueObservation<[ClipboardItem]> {
        await database.observeCollection(collectionID: collectionID, limit: limit)
    }

    func createCollection(name: String, createdAt: Date = .now) async throws -> ClipboardCollection {
        try await database.createCollection(name: name, createdAt: createdAt)
    }

    func moveToCollection(itemID: Int64, collectionID: Int64?) async throws {
        try await database.moveToCollection(itemID: itemID, collectionID: collectionID)
    }

    func removeFromHistory(itemID: Int64) async throws {
        try await database.removeFromHistory(itemID: itemID)
    }

    func deletePermanently(itemID: Int64) async throws {
        try await database.deletePermanently(itemID: itemID)
    }

    func removeCollection(collectionID: Int64) async throws {
        try await database.removeCollection(collectionID: collectionID)
    }

    func clearHistory() async throws {
        try await database.clearHistory()
    }

    func applyRetentionPolicy(_ policy: ClipboardRetentionPolicy, now: Date = .now) async throws {
        try await database.applyRetentionPolicy(policy, now: now)
    }
}
