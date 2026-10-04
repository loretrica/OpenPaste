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
        copiedAt: Date,
        retentionPolicy: ClipboardRetentionPolicy
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
    func pruneExpiredHistory(now: Date) async throws
}

extension ClipboardStore {
    func recordCopy(
        _ content: String,
        sourceAppBundleID: String?,
        copiedAt: Date
    ) async throws -> ClipboardItem? {
        try await recordCopy(
            content,
            sourceAppBundleID: sourceAppBundleID,
            copiedAt: copiedAt,
            retentionPolicy: .oneMonth)
    }
}

protocol LinkMetadataLoading: Sendable {
    func metadata(for url: URL) async throws -> ClipboardLinkMetadata?
}
