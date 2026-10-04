import Foundation
import GRDB

actor ClipboardRepository: ClipboardStore {
    private let database: AppDatabase
    private let metadataLoader: any LinkMetadataLoading
    private var metadataTasks: [Int64: Task<Void, Never>] = [:]

    init(database: AppDatabase, metadataLoader: any LinkMetadataLoading = URLSessionMetadataLoader()) {
        self.database = database
        self.metadataLoader = metadataLoader
    }

    deinit {
        metadataTasks.values.forEach { $0.cancel() }
    }

    func recordCopy(
        _ content: String,
        sourceAppBundleID: String?,
        copiedAt: Date = .now,
        retentionPolicy: ClipboardRetentionPolicy = .oneMonth
    ) async throws -> ClipboardItem? {
        guard !content.isEmpty else { return nil }

        let classified = ClipboardContent.classify(content)
        let item = try await database.recordCopy(
            content: classified,
            sourceAppBundleID: sourceAppBundleID,
            copiedAt: copiedAt,
            retentionPolicy: retentionPolicy)

        guard classified.kind == .link,
              item.title == nil,
              item.linkDescription == nil,
              let canonicalURL = classified.canonicalURL,
              let url = URL(string: canonicalURL),
              let itemID = item.id
        else {
            return item
        }

        enqueueMetadata(for: url, itemID: itemID)

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

    func pruneExpiredHistory(now: Date = .now) async throws {
        try await database.pruneExpiredHistory(now: now)
    }

    private func enqueueMetadata(for url: URL, itemID: Int64) {
        guard metadataTasks[itemID] == nil else { return }

        let database = self.database
        let metadataLoader = self.metadataLoader
        metadataTasks[itemID] = Task { [weak self, database, metadataLoader] in
            do {
                if let metadata = try await metadataLoader.metadata(for: url) {
                    try Task.checkCancellation()
                    try await database.updateLinkMetadata(itemID: itemID, metadata: metadata)
                }
            } catch {
                // The saved URL remains available if metadata loading fails.
            }
            await self?.metadataTaskDidFinish(itemID: itemID)
        }
    }

    private func metadataTaskDidFinish(itemID: Int64) {
        metadataTasks[itemID] = nil
    }
}
