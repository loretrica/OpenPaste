import Foundation
import GRDB

enum ClipboardStoreError: LocalizedError, Sendable {
    case emptyCollectionName
    case invalidLink
    case unsupportedOperation
    case invalidColor
    case itemNotFound

    var errorDescription: String? {
        switch self {
        case .emptyCollectionName:
            "Il nome della raccolta non può essere vuoto."
        case .invalidLink:
            "Il link non è valido."
        case .unsupportedOperation:
            "L'operazione non è supportata da questo archivio."
        case .invalidColor:
            "Il colore deve essere un valore HEX a sei cifre."
        case .itemNotFound:
            "L'elemento non esiste più."
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

    func recordCopy(
        _ payload: ClipboardPayload,
        sourceAppBundleID: String?,
        copiedAt: Date,
        retentionPolicy: ClipboardRetentionPolicy
    ) async throws -> ClipboardItem?

    func payload(for item: ClipboardItem) async throws -> ClipboardPayload
    func fetchItems(query: ClipboardQuery, limit: Int, offset: Int) async throws -> [ClipboardItem]
    func observeItems(query: ClipboardQuery, limit: Int) async -> AsyncValueObservation<[ClipboardItem]>

    func history(limit: Int) async throws -> [ClipboardItem]
    func collections() async throws -> [ClipboardCollection]
    func sourceApplicationBundleIDs() async throws -> [String]
    func collectionItems(collectionID: Int64, limit: Int) async throws -> [ClipboardItem]
    func search(query: String, limit: Int, offset: Int) async throws -> [ClipboardItem]
    func observeHistory(limit: Int) async -> AsyncValueObservation<[ClipboardItem]>
    func observeCollections() async -> AsyncValueObservation<[ClipboardCollection]>
    func observeCollection(
        collectionID: Int64,
        limit: Int
    ) async -> AsyncValueObservation<[ClipboardItem]>

    func createCollection(name: String, createdAt: Date) async throws -> ClipboardCollection
    func updateCollection(collectionID: Int64, name: String, colorHex: String) async throws
    func reorderCollections(ids: [Int64]) async throws
    func reorderItems(ids: [Int64], collectionID: Int64) async throws
    func renameItem(itemID: Int64, title: String?) async throws
    func updateText(itemID: Int64, content: String, language: String?) async throws
    func updatePayload(itemID: Int64, payload: ClipboardPayload) async throws
    func setItemKind(itemID: Int64, kind: ClipboardItemKind, language: String?) async throws
    func moveItems(
        ids: [Int64],
        to collectionID: Int64?,
        retentionPolicy: ClipboardRetentionPolicy,
        now: Date
    ) async throws
    func deleteCollectionPreservingItems(
        collectionID: Int64,
        retentionPolicy: ClipboardRetentionPolicy,
        now: Date
    ) async throws

    func moveToCollection(itemID: Int64, collectionID: Int64?) async throws
    func removeFromHistory(itemID: Int64) async throws
    func deletePermanently(itemID: Int64) async throws
    func removeCollection(collectionID: Int64) async throws
    func clearHistory() async throws
    func pruneExpiredHistory(now: Date) async throws
}

extension ClipboardStore {
    func sourceApplicationBundleIDs() async throws -> [String] {
        let items = try await history(limit: 100)
        return Array(Set(items.compactMap(\.sourceAppBundleID))).sorted()
    }

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

    func recordCopy(
        _ payload: ClipboardPayload,
        sourceAppBundleID: String?,
        copiedAt: Date,
        retentionPolicy: ClipboardRetentionPolicy
    ) async throws -> ClipboardItem? {
        guard payload.representations.isEmpty, payload.files.isEmpty else {
            throw ClipboardStoreError.unsupportedOperation
        }
        return try await recordCopy(
            payload.content,
            sourceAppBundleID: sourceAppBundleID,
            copiedAt: copiedAt,
            retentionPolicy: retentionPolicy)
    }

    func payload(for item: ClipboardItem) async throws -> ClipboardPayload {
        ClipboardPayload.restoring(item)
    }

    func fetchItems(query: ClipboardQuery, limit: Int, offset: Int) async throws -> [ClipboardItem] {
        let items: [ClipboardItem]
        if !query.text.isEmpty {
            items = try await search(query: query.text, limit: limit + max(0, offset), offset: 0)
        } else {
            switch query.scope {
            case .history:
                items = try await history(limit: limit + max(0, offset))
            case let .collection(collectionID):
                items = try await collectionItems(
                    collectionID: collectionID,
                    limit: limit + max(0, offset))
            case .all:
                items = try await history(limit: limit + max(0, offset))
            }
        }
        let matching = items.filter { item in
            if let kind = query.filter.kind, item.kind != kind { return false }
            if let source = query.filter.sourceAppBundleID, item.sourceAppBundleID != source { return false }
            if let from = query.filter.fromDate, item.lastCopiedAt < from { return false }
            if let to = query.filter.toDate, item.lastCopiedAt > to { return false }
            return true
        }
        let start = min(max(0, offset), matching.count)
        return Array(matching.dropFirst(start).prefix(max(0, limit)))
    }

    func observeItems(query: ClipboardQuery, limit: Int) async -> AsyncValueObservation<[ClipboardItem]> {
        switch query.scope {
        case .history, .all:
            await observeHistory(limit: limit)
        case let .collection(collectionID):
            await observeCollection(collectionID: collectionID, limit: limit)
        }
    }

    func updateCollection(collectionID: Int64, name: String, colorHex: String) async throws {
        throw ClipboardStoreError.unsupportedOperation
    }

    func reorderCollections(ids: [Int64]) async throws {
        throw ClipboardStoreError.unsupportedOperation
    }

    func reorderItems(ids: [Int64], collectionID: Int64) async throws {
        throw ClipboardStoreError.unsupportedOperation
    }

    func renameItem(itemID: Int64, title: String?) async throws {
        throw ClipboardStoreError.unsupportedOperation
    }

    func updateText(itemID: Int64, content: String, language: String?) async throws {
        throw ClipboardStoreError.unsupportedOperation
    }

    func updatePayload(itemID: Int64, payload: ClipboardPayload) async throws {
        throw ClipboardStoreError.unsupportedOperation
    }

    func setItemKind(itemID: Int64, kind: ClipboardItemKind, language: String?) async throws {
        throw ClipboardStoreError.unsupportedOperation
    }

    func moveItems(
        ids: [Int64],
        to collectionID: Int64?,
        retentionPolicy: ClipboardRetentionPolicy,
        now: Date
    ) async throws {
        for id in ids {
            try await moveToCollection(itemID: id, collectionID: collectionID)
        }
    }

    func deleteCollectionPreservingItems(
        collectionID: Int64,
        retentionPolicy: ClipboardRetentionPolicy,
        now: Date
    ) async throws {
        throw ClipboardStoreError.unsupportedOperation
    }
}

protocol LinkMetadataLoading: Sendable {
    func metadata(for url: URL) async throws -> ClipboardLinkMetadata?
}
